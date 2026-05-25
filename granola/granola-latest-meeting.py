#!/usr/bin/env python3
"""
Get the document ID of the most recent Granola meeting.
Reads from ~/Library/Application Support/Granola/cache-v3.json
"""
import json
import sys
from pathlib import Path


def get_latest_meeting_doc_id() -> str | None:
    cache_path = Path.home() / "Library/Application Support/Granola/cache-v3.json"
    if not cache_path.exists():
        return None

    with open(cache_path) as f:
        data = json.load(f)

    inner = json.loads(data["cache"])
    docs = inner.get("state", {}).get("documents", {})

    # Filter: non-deleted documents (include valid_meeting=None - some meetings don't have it set)
    meetings = [
        (doc_id, doc)
        for doc_id, doc in docs.items()
        if not doc.get("deleted_at") and doc.get("created_at")
    ]
    if not meetings:
        return None

    meetings.sort(key=lambda x: x[1].get("created_at", ""), reverse=True)
    return meetings[0][0]


def main() -> None:
    doc_id = get_latest_meeting_doc_id()
    if doc_id:
        print(doc_id)
    else:
        sys.stderr.write("No meetings found in Granola cache\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
