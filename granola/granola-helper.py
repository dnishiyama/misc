#!/usr/bin/env python3
"""
granola-helper: CLI for Granola meeting transcripts and tasks.

  granola-helper meetings              List recent meetings with UUIDs
  granola-helper transcripts           Get transcript for most recent meeting
  granola-helper transcripts --pick    Interactively pick a meeting for transcript
  granola-helper transcripts --uuid X  Get transcript for specific meeting UUID
  granola-helper tasks                 Extract tasks from most recent meeting (uses OpenAI)
  granola-helper tasks --prompt       Output the prompt instead of calling OpenAI
  granola-helper tasks --pick         Interactively pick a meeting for tasks
  granola-helper tasks --uuid X       Extract tasks from specific meeting UUID
"""
import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path


CACHE_PATH = Path.home() / "Library/Application Support/Granola/cache-v3.json"
SUPABASE_PATH = Path.home() / "Library/Application Support/Granola/supabase.json"
PROMPTS_DIR = Path(__file__).parent / "granola-helper-prompts"
DEFAULT_LIMIT = 20


def load_cache() -> dict:
    if not CACHE_PATH.exists():
        sys.stderr.write(f"Granola cache not found at {CACHE_PATH}\n")
        sys.exit(1)
    with open(CACHE_PATH) as f:
        data = json.load(f)
    return json.loads(data["cache"])


def get_meetings(limit: int = DEFAULT_LIMIT) -> list[tuple[str, dict]]:
    inner = load_cache()
    docs = inner.get("state", {}).get("documents", {})
    meetings = [
        (doc_id, doc)
        for doc_id, doc in docs.items()
        if not doc.get("deleted_at") and doc.get("created_at")
    ]
    meetings.sort(key=lambda x: x[1].get("created_at", ""), reverse=True)
    return meetings[:limit]


def get_access_token() -> str:
    if not SUPABASE_PATH.exists():
        sys.stderr.write(f"Granola credentials not found at {SUPABASE_PATH}\n")
        sys.exit(1)
    with open(SUPABASE_PATH) as f:
        data = json.load(f)
    tokens = json.loads(data["workos_tokens"])
    return tokens["access_token"]


def fetch_transcript(doc_id: str) -> list[dict]:
    token = get_access_token()
    url = "https://api.granola.ai/v1/get-document-transcript"
    body = json.dumps({"document_id": doc_id}).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "User-Agent": "Granola/5.354.0",
            "X-Client-Version": "5.354.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            data = resp.read()
            # Handle gzip response (API returns compressed)
            if data[:2] == b"\x1f\x8b":
                import gzip
                data = gzip.decompress(data)
            return json.loads(data.decode())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            sys.stderr.write(f"No transcript found for document {doc_id}\n")
        else:
            sys.stderr.write(f"API error {e.code}: {e.read().decode()}\n")
        sys.exit(1)


def format_transcript(entries: list[dict]) -> str:
    lines = []
    for e in entries:
        speaker = "You" if e.get("source") == "microphone" else "Them"
        ts = e.get("start_timestamp", "")[11:19] if e.get("start_timestamp") else ""
        text = e.get("text", "")
        lines.append(f"[{ts}] {speaker}: {text}")
    return "\n".join(lines)


def resolve_doc_id(uuid_arg: str | None, pick: bool, meetings: list[tuple[str, dict]]) -> str | None:
    if uuid_arg:
        return uuid_arg
    if pick:
        return pick_meeting(meetings)
    if meetings:
        return meetings[0][0]
    return None


def pick_meeting(meetings: list[tuple[str, dict]]) -> str | None:
    if not meetings:
        return None
    sys.stderr.write("\nRecent meetings:\n")
    for i, (doc_id, doc) in enumerate(meetings, 1):
        title = doc.get("title", "Untitled")
        created = doc.get("created_at", "")[:19].replace("T", " ")
        sys.stderr.write(f"  {i}. {title} ({created}) [{doc_id}]\n")
    sys.stderr.write("\nEnter number (or q to quit): ")
    try:
        choice = input().strip()
    except EOFError:
        sys.exit(1)
    if choice.lower() == "q":
        sys.exit(0)
    try:
        idx = int(choice)
        if 1 <= idx <= len(meetings):
            return meetings[idx - 1][0]
    except ValueError:
        pass
    sys.stderr.write("Invalid selection\n")
    sys.exit(1)


def cmd_help(args: argparse.Namespace) -> None:
    print(__doc__.strip())
    print()
    parser = args._parser
    parser.print_help()


def cmd_meetings(args: argparse.Namespace) -> None:
    meetings = get_meetings(limit=args.limit)
    for doc_id, doc in meetings:
        title = doc.get("title", "Untitled")
        created = doc.get("created_at", "")[:19].replace("T", " ")
        print(f"{doc_id}  {created}  {title}")


def cmd_transcripts(args: argparse.Namespace) -> None:
    meetings = get_meetings()
    doc_id = resolve_doc_id(args.uuid, args.pick, meetings)
    if not doc_id:
        sys.stderr.write("No meeting selected\n")
        sys.exit(1)
    entries = fetch_transcript(doc_id)
    print(format_transcript(entries))


def call_openai(prompt: str, model: str = "gpt-4o-mini") -> str:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        sys.stderr.write("OPENAI_API_KEY environment variable is required. Set it or use --prompt to output the prompt instead.\n")
        sys.exit(1)
    url = "https://api.openai.com/v1/chat/completions"
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.2,
    }).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            return data["choices"][0]["message"]["content"].strip()
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"OpenAI API error {e.code}: {e.read().decode()}\n")
        sys.exit(1)


def build_tasks_prompt(meetings: list[tuple[str, dict]], doc_id: str) -> str:
    prompt_path = PROMPTS_DIR / "tasks-extract.md"
    if not prompt_path.exists():
        sys.stderr.write(f"Prompt file not found: {prompt_path}\n")
        sys.exit(1)
    entries = fetch_transcript(doc_id)
    transcript = format_transcript(entries)
    meeting_info = next((d for _id, d in meetings if _id == doc_id), {})
    title = meeting_info.get("title", "Meeting")
    prompt_content = prompt_path.read_text()
    return f"""{prompt_content}

---

## Transcript: {title}

{transcript}

---

Extract the tasks from the transcript above. Remember to consider homonyms, speech-to-text errors, and conversational context."""


def cmd_tasks(args: argparse.Namespace) -> None:
    meetings = get_meetings()
    doc_id = resolve_doc_id(args.uuid, args.pick, meetings)
    if not doc_id:
        sys.stderr.write("No meeting selected\n")
        sys.exit(1)

    full_prompt = build_tasks_prompt(meetings, doc_id)

    if args.prompt:
        print(full_prompt)
    else:
        sys.stderr.write("Extracting tasks via OpenAI...\n")
        result = call_openai(full_prompt, model=args.model)
        print(result)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="granola-helper",
        description="CLI for Granola meeting transcripts and tasks",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # help
    help_parser = subparsers.add_parser("help", help="Show usage and commands")
    help_parser.set_defaults(func=cmd_help, _parser=parser)

    # meetings
    meetings_parser = subparsers.add_parser("meetings", help="List recent meetings with UUIDs")
    meetings_parser.add_argument(
        "-n", "--limit",
        type=int,
        default=DEFAULT_LIMIT,
        help=f"Max meetings to list (default: {DEFAULT_LIMIT})",
    )
    meetings_parser.set_defaults(func=cmd_meetings)

    # transcripts
    trans_parser = subparsers.add_parser("transcripts", help="Get meeting transcript")
    trans_parser.add_argument("--pick", action="store_true", help="Interactively pick a meeting")
    trans_parser.add_argument("--uuid", type=str, help="Specific meeting document UUID")
    trans_parser.set_defaults(func=cmd_transcripts)

    # tasks
    tasks_parser = subparsers.add_parser("tasks", help="Extract tasks from transcript (uses OpenAI)")
    tasks_parser.add_argument("--pick", action="store_true", help="Interactively pick a meeting")
    tasks_parser.add_argument("--prompt", action="store_true", help="Output the prompt instead of calling OpenAI")
    tasks_parser.add_argument("--uuid", type=str, help="Specific meeting document UUID")
    tasks_parser.add_argument("--model", type=str, default="gpt-4o-mini", help="OpenAI model (default: gpt-4o-mini)")
    tasks_parser.set_defaults(func=cmd_tasks)

    args = parser.parse_args()
    args._parser = parser
    args.func(args)


if __name__ == "__main__":
    main()
