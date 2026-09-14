from datetime import date, datetime, time
from importlib.metadata import version
import fcntl
import json
import os
from pathlib import Path
import time as clock

from falkordb import FalkorDB
from falkordb.graph import Graph
from falkordb.query_result import QueryResult


def canonical(value: object) -> object:
    if isinstance(value, dict):
        return {str(key): canonical(item) for key, item in sorted(value.items())}
    if isinstance(value, (list, tuple)):
        return [canonical(item) for item in value]
    if isinstance(value, (datetime, date, time)):
        return {"type": type(value).__name__, "value": value.isoformat()}
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise TypeError(f"unsupported graph property type: {type(value).__name__}")


def ordered(values: list[object]) -> list[object]:
    return sorted(values, key=lambda value: json.dumps(value, sort_keys=True))


def records(result: QueryResult) -> list[dict[str, object]]:
    columns = [column[1] for column in result.header]
    return [dict(zip(columns, row)) for row in result.result_set]


def inventory(graph: Graph) -> dict[str, object]:
    nodes = records(graph.ro_query(
        "MATCH (node) RETURN id(node) AS id, labels(node) AS labels, properties(node) AS properties ORDER BY id(node)"
    ))
    relationships = records(graph.ro_query(
        "MATCH (source)-[relationship]->(target) RETURN id(relationship) AS id, id(source) AS source, "
        "id(target) AS target, type(relationship) AS type, properties(relationship) AS properties ORDER BY id(relationship)"
    ))
    indexes = records(graph.list_indices())
    for index in indexes:
        index.pop("info", None)
    return canonical({
        "nodes": nodes,
        "relationships": relationships,
        "node_count": len(nodes),
        "relationship_count": len(relationships),
        "indexes": ordered(indexes),
        "constraints": ordered(graph.list_constraints()),
        "labels": sorted(row[0] for row in graph.ro_query("CALL db.labels()").result_set),
        "relationship_types": sorted(row[0] for row in graph.ro_query("CALL db.relationshipTypes()").result_set),
        "property_keys": sorted(row[0] for row in graph.ro_query("CALL db.propertyKeys()").result_set),
    })


def plan(database: FalkorDB, identifiers: list[str], references: dict[str, object]) -> dict[str, object]:
    existing = set(database.list_graphs())
    graphs = []
    for identifier in identifiers:
        source_logical = "operator/" + identifier
        target_logical = "personal/" + identifier
        source = "g_" + source_logical.encode("utf-8").hex()
        target = "g_" + target_logical.encode("utf-8").hex()
        graphs.append({
            "operator_id": identifier,
            "source_logical": source_logical,
            "target_logical": target_logical,
            "source_physical": source,
            "target_physical": target,
            "source_exists": source in existing,
            "target_exists": target in existing,
            "source_inventory": inventory(database.select_graph(source)) if source in existing else {},
            "target_inventory": inventory(database.select_graph(target)) if target in existing else {},
            "phase": "planned",
        })
    return {
        "format": "gralkor-personal-graphs-v1",
        "phase": "planned",
        "graphs": graphs,
        "configuration_references": references,
        "versions": {
            "graphiti": version("graphiti-core"),
            "falkordb_client": version("falkordb"),
            "falkordblite": version("falkordblite"),
            "server": database.connection.info("server")["redis_version"],
            "modules": canonical(database.connection.module_list()),
        },
    }


def persist(path: Path, manifest: dict[str, object], create: bool = False) -> None:
    destination = path if create else path.with_suffix(path.suffix + ".tmp")
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if create else os.O_TRUNC)
    with os.fdopen(os.open(destination, flags, 0o600), "w") as stream:
        json.dump(manifest, stream, sort_keys=True, ensure_ascii=False)
        stream.flush()
        os.fsync(stream.fileno())
    if not create:
        os.replace(destination, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def schema_ready(graph: Graph) -> None:
    deadline = clock.monotonic() + 30
    while True:
        definitions = records(graph.list_indices()) + graph.list_constraints()
        statuses = {str(item["status"]).upper() for item in definitions}
        if statuses <= {"OPERATIONAL", "ACTIVE"}:
            return
        if statuses & {"FAILED", "ERROR"} or clock.monotonic() >= deadline:
            raise ValueError(f"graph schema is not operational: {graph.name}: {statuses}")
        clock.sleep(0.01)


def translated(inventory_value: dict[str, object], source: str, target: str) -> dict[str, object]:
    result = json.loads(json.dumps(inventory_value))
    for entity in result["nodes"] + result["relationships"]:
        properties = entity["properties"]
        if properties.get("group_id") == source:
            properties["group_id"] = target
    return result


def advance(database: FalkorDB, path: Path, manifest: dict[str, object]) -> dict[str, object]:
    if manifest["phase"] == "verified":
        return manifest
    for entry in manifest["graphs"]:
        source = database.select_graph(entry["source_physical"])
        target = database.select_graph(entry["target_physical"])
        if inventory(source) != entry["source_inventory"]:
            raise ValueError(f"source changed after inventory: {source.name}")
        if entry["phase"] == "planned":
            entry["phase"] = "copying"
            persist(path, manifest)
        if entry["phase"] == "copying":
            source.copy(target.name)
            schema_ready(target)
            entry["phase"] = "copied"
            persist(path, manifest)
            return manifest
        if entry["phase"] == "copied":
            target.query(
                "MATCH (node) WHERE node.group_id = $source SET node.group_id = $target",
                {"source": source.name, "target": target.name},
            )
            entry["phase"] = "nodes_rewritten"
            persist(path, manifest)
            return manifest
        if entry["phase"] == "nodes_rewritten":
            target.query(
                "MATCH ()-[relationship]->() WHERE relationship.group_id = $source SET relationship.group_id = $target",
                {"source": source.name, "target": target.name},
            )
            entry["phase"] = "relationships_rewritten"
            persist(path, manifest)
            return manifest
        if entry["phase"] == "relationships_rewritten":
            schema_ready(target)
            target_inventory = inventory(target)
            if target_inventory != translated(entry["source_inventory"], source.name, target.name):
                raise ValueError(f"target differs from translated source: {target.name}")
            entry["target_inventory"] = target_inventory
            entry["phase"] = "verified"
            persist(path, manifest)
    manifest["phase"] = "verified"
    persist(path, manifest)
    return manifest


def require_quiescence(evidence: dict[str, object]) -> None:
    if evidence.get("admission_stopped") is not True:
        raise ValueError("quiescence requires admission_stopped=true")
    for kind in ["capture_buffers", "asynchronous_additions", "reflection_workers", "queued_deliveries", "schedulers", "consuming_runtimes", "failed_work"]:
        if type(evidence.get(kind)) is not int or evidence[kind] != 0:
            raise ValueError(f"quiescence requires {kind}=0")


def execute(request: dict[str, object]) -> dict[str, object]:
    with FalkorDB(**request["connection"]) as database:
        action = request["action"]
        if action == "plan":
            return plan(database, request["operator_ids"], request["configuration_references"])
        path = Path(request["journal_path"])
        with open(path.with_suffix(path.suffix + ".lock"), "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if action == "prepare":
                manifest = plan(database, request["operator_ids"], request["configuration_references"])
                persist(path, manifest, create=True)
                return manifest
            require_quiescence(request["quiescence"])
            with open(path) as stream:
                manifest = json.load(stream)
            while manifest["phase"] != "verified":
                manifest = advance(database, path, manifest)
            return manifest
