import json
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
import uvicorn

BASE_DIR = Path(__file__).resolve().parent
GRAPH_FILE = BASE_DIR / "graph.json"
STATIC_DIR = BASE_DIR / "static"

with open(GRAPH_FILE, "r", encoding="utf-8") as f:
    GRAPH = json.load(f)

COMPANY_RULES = {
    "company-a": {"tags": {"shared", "company-a"}},
    "company-b": {"tags": {"shared", "company-b"}},
}

app = FastAPI()
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


def filter_graph(company: str):
    company = (company or "").lower()
    if company not in COMPANY_RULES:
        raise HTTPException(status_code=400, detail=f"Unknown company '{company}'")

    allowed_tags = COMPANY_RULES[company]["tags"]
    visible_nodes = [
        node
        for node in GRAPH["nodes"]
        if allowed_tags.intersection(set(node.get("tags", [])))
    ]
    visible_node_ids = {node["id"] for node in visible_nodes}
    visible_edges = [
        edge
        for edge in GRAPH["edges"]
        if edge["source"] in visible_node_ids and edge["target"] in visible_node_ids
    ]
    return {
        "viewer": company,
        "nodes": visible_nodes,
        "edges": visible_edges,
    }


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/graph")
def graph(company: str = ""):
    return JSONResponse(filter_graph(company))


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/company-a")
def company_a_view():
    return FileResponse(STATIC_DIR / "company-a.html")


@app.get("/company-b")
def company_b_view():
    return FileResponse(STATIC_DIR / "company-b.html")


@app.get("/compare")
def compare_view():
    return FileResponse(STATIC_DIR / "compare.html")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8200)
