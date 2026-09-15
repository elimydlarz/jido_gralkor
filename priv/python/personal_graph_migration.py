from datetime import date, datetime, time
from importlib.metadata import version
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import time as clock

from falkordb import FalkorDB
from falkordb.graph import Graph
from falkordb.query_result import QueryResult
from redis.backoff import NoBackoff
from redis.exceptions import ConnectionError, TimeoutError
from redis.retry import Retry


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


def uuid_inventory(entities: list[dict[str, object]], nodes: bool) -> dict[str, object]:
    by_kind = {}
    for entity in entities:
        uuid = entity["properties"].get("uuid")
        for kind in entity["labels"] if nodes else [entity["type"]]:
            values = by_kind.setdefault(kind, [])
            if uuid is not None:
                values.append(uuid)
    return {kind: {"count": len(values), "values": ordered(list(set(values)))} for kind, values in by_kind.items()}


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
        "node_uuids": uuid_inventory(nodes, True),
        "relationship_uuids": uuid_inventory(relationships, False),
        "indexes": ordered(indexes),
        "constraints": ordered(graph.list_constraints()),
        "labels": sorted(row[0] for row in graph.ro_query("CALL db.labels()").result_set),
        "relationship_types": sorted(row[0] for row in graph.ro_query("CALL db.relationshipTypes()").result_set),
        "property_keys": sorted(row[0] for row in graph.ro_query("CALL db.propertyKeys()").result_set),
    })


def plan(database: FalkorDB, identifiers: list[str], references: dict[str, object], identity: dict[str, object]) -> dict[str, object]:
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
        "endpoint_identity": identity,
        "versions": {
            "graphiti": version("graphiti-core"),
            "falkordb_client": version("falkordb"),
            "falkordblite": version("falkordblite"),
            "server": database.connection.info("server")["redis_version"],
            "modules": canonical(database.connection.module_list()),
        },
    }


def persist(path: Path, manifest: dict[str, object], create: bool = False) -> None:
    manifest["integrity"] = manifest_digest(manifest)
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


def manifest_digest(manifest: dict[str, object]) -> str:
    content = {key: value for key, value in manifest.items() if key != "integrity"}
    encoded = json.dumps(content, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def endpoint_identity(connection: dict[str, object]) -> dict[str, object]:
    socket = connection.get("unix_socket_path")
    identity = {"db": connection.get("db", 0), "username": connection.get("username")}
    if isinstance(socket, str) and socket.strip():
        identity.update({"kind": "unix", "unix_socket_path": socket})
    else:
        identity.update({"kind": "tcp", "host": connection.get("host"), "port": connection.get("port")})
    return canonical(identity)


def validate_endpoint_binding(manifest: dict[str, object], connection: dict[str, object], rebind: object) -> None:
    recorded = manifest.get("endpoint_identity")
    current = endpoint_identity(connection)
    if not isinstance(recorded, dict):
        raise ValueError("journal lacks endpoint identity; prepare a fresh migration journal")
    if current == recorded:
        if rebind is not None:
            raise ValueError("endpoint rebind requires a different graph endpoint")
        return
    if not isinstance(rebind, dict) or rebind.get("prior_endpoint") != recorded or rebind.get("prior_endpoint_retired") is not True:
        raise ValueError("journal endpoint identity differs; require explicit controlled endpoint rebind")
    if rebind.get("new_endpoint") not in (None, current):
        raise ValueError("controlled endpoint rebind does not describe the supplied endpoint")


def validate_manifest(manifest: dict[str, object]) -> None:
    if manifest.get("integrity") != manifest_digest(manifest):
        raise ValueError("manifest integrity check failed")
    if manifest.get("format") != "gralkor-personal-graphs-v1":
        raise ValueError("unsupported manifest format")
    phase = manifest.get("phase")
    if phase not in {"planned", "verified", "rolling_back", "rolled_back"}:
        raise ValueError("invalid manifest phase")
    entries = manifest["graphs"]
    validate_identities([entry["operator_id"] for entry in entries])
    unfinished = False
    for entry in entries:
        source = "operator/" + entry["operator_id"]
        target = "personal/" + entry["operator_id"]
        if (
            entry["source_logical"] != source
            or entry["target_logical"] != target
            or entry["source_physical"] != "g_" + source.encode("utf-8").hex()
            or entry["target_physical"] != "g_" + target.encode("utf-8").hex()
            or entry["source_physical"] == entry["target_physical"]
        ):
            raise ValueError("manifest identity mapping is inconsistent")
        graph_phase = entry["phase"]
        forward = {"planned", "copying", "copied", "nodes_rewritten", "relationships_rewritten", "verified"}
        if graph_phase not in forward | {"rollback_pending", "rolled_back"}:
            raise ValueError("invalid manifest graph phase")
        if phase == "verified" and graph_phase != "verified":
            raise ValueError("manifest completion phases are inconsistent")
        if phase == "rolled_back" and graph_phase != "rolled_back":
            raise ValueError("manifest rollback phases are inconsistent")
        if phase == "planned":
            if graph_phase not in forward or (unfinished and graph_phase != "planned"):
                raise ValueError("manifest progression is inconsistent")
            unfinished = unfinished or graph_phase != "verified"


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


def validate_progress(database: FalkorDB, manifest: dict[str, object]) -> None:
    existing = set(database.list_graphs())
    for entry in manifest["graphs"]:
        source = database.select_graph(entry["source_physical"])
        target = database.select_graph(entry["target_physical"])
        if source.name not in existing or inventory(source) != entry["source_inventory"]:
            raise ValueError(f"source changed after inventory: {source.name}")
        active = source.ro_query(
            "MATCH (claim:_GralkorEpisodeClaim) WHERE claim.owner IS NOT NULL "
            "AND coalesce(claim.lease_until_ms, 0) > timestamp() RETURN claim.uuid"
        ).result_set
        if active:
            raise ValueError(f"active episode claim: {source.name}")
        if entry["phase"] in {"planned", "rolled_back"}:
            if target.name in existing:
                raise ValueError(f"target graph already exists: {target.name}")
        elif target.name in existing:
            schema_ready(target)
            actual = inventory(target)
            if entry["phase"] == "rollback_pending":
                matching = actual == entry["rollback_inventory"]
            elif entry["phase"] == "verified":
                matching = actual == entry["target_inventory"]
            else:
                matching = translated(actual, target.name, source.name) == entry["source_inventory"]
            if not matching:
                raise ValueError(f"target contains conflicting data: {target.name}")
        elif entry["phase"] == "copying":
            original_run_id = entry.get("copy_server_run_id")
            if original_run_id is None:
                raise ValueError(
                    "copy intent lacks its server identity; retain this journal and require "
                    "controlled server recovery before preparing a fresh migration"
                )
            if database.connection.info("server")["run_id"] == original_run_id:
                raise ValueError(
                    "GRAPH.COPY outcome is uncertain while its target is absent; "
                    "wait for a matching complete target or require controlled server recovery "
                    "before resume or rollback"
                )
        elif entry["phase"] != "rollback_pending":
            raise ValueError(f"target graph missing: {target.name}")


def advance(database: FalkorDB, path: Path, manifest: dict[str, object]) -> dict[str, object]:
    if manifest["phase"] in {"rolling_back", "rolled_back"}:
        raise ValueError("migration has entered rollback; prepare a new manifest to migrate again")
    validate_progress(database, manifest)
    if manifest["phase"] == "verified":
        return manifest
    for entry in manifest["graphs"]:
        source = database.select_graph(entry["source_physical"])
        target = database.select_graph(entry["target_physical"])
        if entry["phase"] == "planned":
            entry["phase"] = "copying"
            entry["copy_server_run_id"] = database.connection.info("server")["run_id"]
            persist(path, manifest)
        if entry["phase"] == "copying":
            if target.name not in database.list_graphs():
                entry["copy_server_run_id"] = database.connection.info("server")["run_id"]
                persist(path, manifest)
                try:
                    source.copy(target.name)
                except (ConnectionError, TimeoutError) as error:
                    raise ValueError(
                        "GRAPH.COPY outcome is uncertain; copy intent remains journaled. "
                        "A timeout does not cancel server work. Verify the target before resuming."
                    ) from error
            schema_ready(target)
            entry["target_exists"] = True
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


def rollback(database: FalkorDB, path: Path, manifest: dict[str, object]) -> dict[str, object]:
    validate_progress(database, manifest)
    if manifest["phase"] == "rolled_back":
        return manifest
    manifest["phase"] = "rolling_back"
    persist(path, manifest)
    for entry in manifest["graphs"]:
        if entry["phase"] == "rolled_back":
            continue
        target = database.select_graph(entry["target_physical"])
        if target.name in database.list_graphs():
            entry["rollback_inventory"] = inventory(target)
            entry["phase"] = "rollback_pending"
            persist(path, manifest)
            target.delete()
        entry["target_exists"] = False
        entry["phase"] = "rolled_back"
        persist(path, manifest)
    manifest["phase"] = "rolled_back"
    persist(path, manifest)
    return manifest


def require_quiescence(evidence: dict[str, object]) -> None:
    if evidence.get("admission_stopped") is not True:
        raise ValueError("quiescence requires admission_stopped=true")
    for kind in ["capture_buffers", "asynchronous_additions", "reflection_workers", "queued_deliveries", "schedulers", "consuming_runtimes", "failed_work"]:
        if type(evidence.get(kind)) is not int or evidence[kind] != 0:
            raise ValueError(f"quiescence requires {kind}=0")


def validate_preparation(manifest: dict[str, object]) -> None:
    references = manifest["configuration_references"]
    for destination in references.get("destinations", []):
        if destination == "personal" or destination.startswith("personal/"):
            raise ValueError(f"Destination namespace conflict: {destination}")
    if "personal-chat" in references.get("lenses", []):
        raise ValueError("Lens namespace conflict: personal-chat")
    for graph in manifest["graphs"]:
        if not graph["source_exists"]:
            raise ValueError(f"source graph missing: {graph['source_physical']}")
        if graph["target_exists"]:
            raise ValueError(f"target graph already exists: {graph['target_physical']}")
        for entity in graph["source_inventory"]["nodes"] + graph["source_inventory"]["relationships"]:
            group_id = entity["properties"].get("group_id")
            if group_id is not None and group_id != graph["source_physical"]:
                raise ValueError(f"incompatible stored group identity: {graph['source_physical']}: {group_id}")


def validate_identities(identifiers: list[str]) -> None:
    if not isinstance(identifiers, list) or not identifiers:
        raise ValueError("operator identities must be a non-empty list")
    if any(not isinstance(identity, str) or not identity.strip() or identity.startswith(("operator/", "personal/")) for identity in identifiers):
        raise ValueError("operator identities must be non-blank identifiers, not resolved graph names")
    if len(set(identifiers)) != len(identifiers):
        raise ValueError("operator identities must be distinct")


def execute(request: dict[str, object]) -> dict[str, object]:
    action = request["action"]
    if action not in {"plan", "prepare", "advance", "apply", "rollback"}:
        raise ValueError("unsupported migration operation")
    if action in {"plan", "prepare"}:
        validate_identities(request["operator_ids"])
    connection = request["connection"]
    socket = connection.get("unix_socket_path")
    host = connection.get("host")
    port = connection.get("port")
    if not (
        isinstance(socket, str) and socket.strip()
        or isinstance(host, str) and host.strip() and type(port) is int and 0 < port <= 65535
    ):
        raise ValueError("an explicit graph endpoint requires a Unix socket or host and port")
    connection = dict(connection)
    for field, default in (("socket_timeout", 30), ("socket_connect_timeout", 5)):
        value = connection.setdefault(field, default)
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise ValueError(f"finite positive connection deadline required: {field}")
    # Mutations must never be replayed after losing their server response.
    connection["retry"] = Retry(NoBackoff(), 0)
    connection["retry_on_error"] = []
    if action == "plan":
        with FalkorDB(**connection) as database:
            return plan(database, request["operator_ids"], request["configuration_references"], endpoint_identity(connection))
    path = Path(request["journal_path"])
    with open(path.with_suffix(path.suffix + ".lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if action == "prepare":
            with FalkorDB(**connection) as database:
                manifest = plan(database, request["operator_ids"], request["configuration_references"], endpoint_identity(connection))
                validate_preparation(manifest)
                persist(path, manifest, create=True)
                return manifest
        require_quiescence(request["quiescence"])
        with open(path) as stream:
            manifest = json.load(stream)
        validate_manifest(manifest)
        rebind = request.get("endpoint_rebind")
        validate_endpoint_binding(manifest, connection, rebind)
        with FalkorDB(**connection) as database:
            if isinstance(rebind, dict):
                current_run_id = database.connection.info("server")["run_id"]
                if any(entry["phase"] == "copying" and entry.get("copy_server_run_id") == current_run_id for entry in manifest["graphs"]):
                    raise ValueError("controlled endpoint rebind requires a new server run identity for outstanding copy")
                validate_progress(database, manifest)
                manifest["endpoint_identity"] = endpoint_identity(connection)
                manifest["endpoint_rebound_from"] = rebind["prior_endpoint"]
                persist(path, manifest)
            if action == "rollback":
                return rollback(database, path, manifest)
            if action == "advance":
                return advance(database, path, manifest)
            validate_progress(database, manifest)
            while manifest["phase"] != "verified":
                manifest = advance(database, path, manifest)
            return manifest
