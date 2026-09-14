from datetime import date, datetime, time
from importlib.metadata import version
import json

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


def execute(request: dict[str, object]) -> dict[str, object]:
    with FalkorDB(**request["connection"]) as database:
        return plan(database, request["operator_ids"], request["configuration_references"])
