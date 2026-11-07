"""Import reviewed meme captions through the live plugin; default is read-only.

Only --apply writes metadata/config or calls the existing local embedding model.
No vision/chat model or QQ send API is used.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

PACK = "legacy-pack"
EXT = "/plugins/extensions/meme_manager"
IMAGES = {".jpg", ".jpeg", ".png", ".gif", ".webp"}


def read_json(path):
    value = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError("Expected JSON object")
    return value


def file_hash(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def local_embedding(config):
    candidates = []
    for provider in config.get("provider", []):
        if not isinstance(provider, dict) or not provider.get("enable", True):
            continue
        if provider.get("provider_type") != "embedding" or provider.get("type") != "openai_embedding":
            continue
        base = str(provider.get("embedding_api_base") or "").rstrip("/")
        try:
            parsed = urllib.parse.urlsplit(base)
            is_local = (parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
                        and parsed.port == 11434 and not parsed.username and not parsed.password
                        and not parsed.query and not parsed.fragment)
        except ValueError:
            continue
        if (is_local and not provider.get("proxy") and provider.get("embedding_model") in {"bge-m3", "bge-m3:latest"}
                and type(provider.get("embedding_dimensions")) is int and provider["embedding_dimensions"] == 1024
                and isinstance(provider.get("id"), str) and provider["id"]):
            candidates.append(dict(provider))
    if len(candidates) != 1:
        raise ValueError("Expected exactly one enabled local Ollama bge-m3/1024 provider")
    return candidates[0]


def prepare(root, captions=None, *, expected_count=51):
    root = Path(root).resolve()
    captions = Path(captions) if captions else root / "表情素材" / "captions.json"
    entries = read_json(captions).get(PACK)
    if not isinstance(entries, dict) or len(entries) != expected_count:
        raise ValueError("Caption entry count does not match the expected pack")
    data = root / "astrbot" / "data"
    pack = data / "plugin_data" / "meme_manager" / "packs" / PACK
    images = pack / "memes" / "default"
    if not images.is_dir() or images.is_symlink():
        raise ValueError("Expected real default image directory")
    actual = {p.name for p in images.iterdir() if p.is_file() and p.suffix.lower() in IMAGES}
    if set(entries) != actual:
        raise ValueError("Caption filenames and installed image filenames differ")
    records = []
    for filename, value in sorted(entries.items()):
        if (not isinstance(filename, str) or Path(filename).name != filename or "/" in filename or "\\" in filename
                or not isinstance(value, dict)):
            raise ValueError("Invalid image caption entry")
        image = images / filename
        if image.is_symlink() or not image.resolve().is_relative_to(images.resolve()):
            raise ValueError("Symlink images are not accepted")
        caption, tags, visible = value.get("caption"), value.get("tags"), value.get("visible_text", "")
        if not isinstance(caption, str) or not caption.strip() or len(caption) > 4000:
            raise ValueError("Invalid caption")
        if (not isinstance(tags, list) or not 1 <= len(tags) <= 50
                or any(not isinstance(tag, str) or not tag.strip() or len(tag) > 80 for tag in tags)):
            raise ValueError("Invalid caption tags")
        if any(tag.startswith(("category:", "分类:")) for tag in tags):
            raise ValueError("Category tags are maintained by the plugin")
        if not isinstance(visible, str) or len(visible) > 4000:
            raise ValueError("Invalid visible text")
        records.append({"filename": filename, "caption": caption.strip(), "tags": tags,
                        "visible_text": visible.strip(), "sha256": file_hash(image)})
    plugin_config = data / "config" / "meme_manager_config.json"
    read_json(plugin_config)
    provider = local_embedding(read_json(data / "cmd_config.json"))
    return {"root": root, "captions": captions, "pack": pack, "plugin_config": plugin_config,
            "index": data / "plugin_data" / "meme_manager" / "semantic_indexes" / PACK,
            "provider": provider, "records": records}


class Dashboard:
    def __init__(self, root):
        fields = {}
        for line in (Path(root) / "private" / "backend.txt").read_text(encoding="utf-8-sig").splitlines():
            key, sep, value = line.replace("：", ":", 1).partition(":")
            if sep:
                fields[key.strip().lower()] = value.strip()
        self.base = (fields.get("url") or "http://127.0.0.1:6185").split()[0].rstrip("/")
        parsed = urllib.parse.urlsplit(self.base)
        if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("Dashboard must be local")
        self._username, self._password = fields["username"], fields["password"]
        self._token = None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _send(self, method, path, body=None, *, timeout=60):
        request = urllib.request.Request(self.base + "/api/v1" + path,
                                        data=json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None,
                                        method=method, headers={"Content-Type": "application/json"})
        if self._token:
            request.add_header("Authorization", "Bearer " + self._token)
        with self.opener.open(request, timeout=timeout) as response:
            result = json.load(response)
        if not isinstance(result, dict) or result.get("status") == "error":
            raise RuntimeError("Local dashboard operation failed")
        return result

    def login(self):
        self._token = None
        for password in (self._password, hashlib.md5(self._password.encode()).hexdigest()):
            try:
                result = self._send("POST", "/auth/login", {"username": self._username, "password": password})
            except urllib.error.HTTPError:
                continue
            token = result.get("data", {}).get("token")
            if isinstance(token, str) and token:
                self._token = token
                return
        raise RuntimeError("Local dashboard login failed")

    def request(self, method, path, body=None, *, timeout=60):
        try:
            result = self._send(method, path, body, timeout=timeout)
        except urllib.error.HTTPError as error:
            if error.code != 401:
                raise RuntimeError(f"Local dashboard HTTP {error.code}") from None
            error.close()
            self.login()
            result = self._send(method, path, body, timeout=timeout)
        if result.get("status") in {"ok", "success"} and isinstance(result.get("data"), dict):
            return result["data"]
        return result


def settings_values(snapshot):
    return {item["path"]: item.get("value") for item in snapshot.get("fields", []) if isinstance(item, dict) and "path" in item}


def update_settings(api, changes):
    snapshot = api.request("GET", EXT + "/settings/config")
    if not isinstance(snapshot.get("revision"), str):
        raise RuntimeError("Missing settings revision")
    values = settings_values(snapshot)
    updates = {key: value for key, value in changes.items() if values.get(key) != value}
    if not updates:
        return
    if not set(updates).issubset(values):
        raise RuntimeError("Plugin settings schema does not contain required semantic fields")
    result = api.request("POST", EXT + "/settings/config", {"revision": snapshot["revision"], "changes": updates})
    if result.get("applied") is not True:
        raise RuntimeError("Semantic settings were saved but not applied")
    after = settings_values(api.request("GET", EXT + "/settings/config"))
    if any(after.get(key) != value for key, value in changes.items()):
        raise RuntimeError("Semantic settings verification failed")


def backup_inputs(plan, backup=None):
    snapshots = plan["root"] / "private" / "snapshots"
    backup = (Path(backup).resolve() if backup else snapshots / ("voice-round3-" + datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]))
    if not backup.resolve().is_relative_to(snapshots.resolve()) or not backup.name.startswith("voice-round3-"):
        raise ValueError("Semantic backup must be a voice-round3 snapshot inside private")
    target = backup / "semantics"
    target.mkdir(parents=True, exist_ok=False)
    sources = {"semantic_metadata.json": plan["pack"] / "semantic_metadata.json",
               "meme_manager_config.json": plan["plugin_config"], "captions.json": plan["captions"],
               "index": plan["index"]}
    manifest = {}
    for name, source in sources.items():
        manifest[name] = source.exists()
        if source.is_dir():
            shutil.copytree(source, target / name)
        elif source.exists():
            shutil.copy2(source, target / name)
    (target / "backup-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return backup


def apply(plan, api, *, backup=None):
    backup = backup_inputs(plan, backup)
    api.login()
    try:
        # Keep selection disabled until every caption and vector is verified.
        update_settings(api, {"semantic.enabled": False,
                              "semantic.embedding_provider_id": plan["provider"]["id"]})
        for record in plan["records"]:
            image = plan["pack"] / "memes" / "default" / record["filename"]
            if file_hash(image) != record["sha256"]:
                raise RuntimeError("Image changed after validation")
            query = urllib.parse.urlencode({"managed_pack_id": PACK, "category": "default", "filename": record["filename"]})
            detail = api.request("GET", EXT + "/meme_image_semantic?" + query).get("semantic", {})
            if detail.get("content_sha256") != record["sha256"] or not isinstance(detail.get("entry_id"), str):
                raise RuntimeError("Image snapshot does not match the validated file")
            result = api.request("POST", EXT + "/semantic/save_image", {
                "pack_id": PACK, "expected_pack_id": PACK, "category": "default", "filename": record["filename"],
                "expected_content_sha256": record["sha256"], "expected_entry_id": detail["entry_id"],
                "caption": record["caption"], "tags": record["tags"], "visible_text": record["visible_text"],
                "category_decision": "keep",
            })
            saved = result.get("semantic", {})
            if (saved.get("caption_status") != "done" or saved.get("manual_override") is not True
                    or saved.get("caption") != record["caption"]):
                raise RuntimeError("Manual caption save was not confirmed")
        built = api.request("POST", EXT + "/semantic/rebuild-index", {"pack_id": PACK, "force": True}, timeout=600)
        if (built.get("item_count") != len(plan["records"])
                or built.get("embedding_provider_id") != plan["provider"]["id"]
                or built.get("embedding_dimension") != 1024):
            raise RuntimeError("Built index does not match this local provider and complete pack")
        status = api.request("GET", EXT + "/semantic/status?pack_id=" + PACK)
        if status.get("index_ready") is not True:
            raise RuntimeError("Live plugin did not accept the completed index")
        update_settings(api, {"semantic.enabled": True, "semantic.min_score": 0.25,
                              "semantic.embedding_provider_id": plan["provider"]["id"]})
        final = api.request("GET", EXT + "/semantic/status?pack_id=" + PACK)
        if final.get("index_ready") is not True or final.get("semantic_enabled") is not True:
            raise RuntimeError("Semantic selection did not become ready")
    except Exception:
        try:
            update_settings(api, {"semantic.enabled": False})
        except Exception:
            pass
        raise RuntimeError("Semantic import incomplete; selection disabled where possible; private snapshot retained") from None
    return {"ok": True, "captions": len(plan["records"]), "index_items": built["item_count"],
            "embedding_dimension": 1024, "semantic_enabled": True, "backup": str(backup)}


def verify_query(plan, query="猫"):
    """Check the on-disk FAISS selection with only the same local embedding model."""
    if not isinstance(query, str) or not query.strip() or len(query) > 100:
        raise ValueError("Invalid local verification query")
    query = query.strip()
    coverage = sum(query in (record["caption"] + " " + " ".join(record["tags"])) for record in plan["records"])
    if not coverage:
        # A fixture such as "cat" is not a valid retrieval acceptance criterion
        # when the reviewed caption source does not describe any cats. Report
        # this explicitly, without running a model or claiming the index broke.
        return {"local_only": True, "caption_source_query_coverage": 0, "retrieval_tested": False,
                "reason": "query_not_covered_by_source_captions"}
    import faiss
    import numpy as np

    provider = local_embedding({"provider": [plan["provider"]]})
    manifest = read_json(plan["index"] / "index_manifest.json")
    if (manifest.get("embedding_provider_id") != provider["id"] or manifest.get("embedding_dimension") != 1024
            or manifest.get("item_count") != len(plan["records"])):
        raise RuntimeError("Index does not match this validated provider/pack")
    filename = str(manifest.get("index_file") or "")
    if not re.fullmatch(r"index-[0-9a-f]{32}\.faiss", filename):
        raise RuntimeError("Invalid FAISS index filename")
    index_path = plan["index"] / filename
    if index_path.is_symlink() or not index_path.resolve().is_relative_to(plan["index"].resolve()):
        raise RuntimeError("Invalid FAISS index path")
    request = urllib.request.Request(provider["embedding_api_base"].rstrip("/") + "/embeddings",
                                     data=json.dumps({"model": provider["embedding_model"], "input": query}, ensure_ascii=False).encode("utf-8"),
                                     headers={"Content-Type": "application/json"}, method="POST")
    if provider.get("embedding_api_key"):
        request.add_header("Authorization", "Bearer " + str(provider["embedding_api_key"]))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=60) as response:
        vector = json.load(response)["data"][0]["embedding"]
    if (not isinstance(vector, list) or len(vector) != 1024
            or any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) for value in vector)
            or not any(vector)):
        raise RuntimeError("Invalid local embedding vector")
    matrix = np.asarray([vector], dtype="float32")
    faiss.normalize_L2(matrix)
    index = faiss.read_index(str(index_path))
    if index.d != 1024 or index.ntotal != len(plan["records"]):
        raise RuntimeError("FAISS index dimensions or item count differ")
    scores, ids = index.search(matrix, min(5, index.ntotal))
    by_id = {int(item["faiss_id"]): key for key, item in manifest["items"].items()}
    metadata = read_json(plan["pack"] / "semantic_metadata.json")["images"]
    matches = []
    for faiss_id in ids[0]:
        item = metadata.get(by_id.get(int(faiss_id)), {})
        text = str(item.get("caption") or "") + " " + " ".join(item.get("tags") or [])
        matches.append(query in text)
    return {"local_only": True, "caption_source_query_coverage": coverage, "retrieval_tested": True,
            "top_caption_mentions_query": bool(matches and matches[0]),
            "top_k_has_query": any(matches), "top_score": round(float(scores[0][0]), 4)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", default=r"E:\dafeiyu")
    parser.add_argument("--captions")
    parser.add_argument("--backup")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--verify-query", nargs="?", const="猫", help="Locally check an existing completed index; default query: 猫")
    args = parser.parse_args()
    plan = prepare(args.dir, args.captions)
    if args.apply:
        result = apply(plan, Dashboard(plan["root"]), backup=args.backup)
    else:
        result = {"ok": True, "dry_run": True, "captions": len(plan["records"]),
                  "filenames_match": True, "local_embedding": True, "embedding_dimension": 1024}
    if args.verify_query:
        result["query_check"] = verify_query(plan, args.verify_query)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({"ok": False, "error": type(error).__name__}))
        sys.exit(1)
