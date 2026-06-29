"""
test_client.py
Minimal remote-caller example using the OpenAI Python SDK against the
llama-server OpenAI-compatible endpoint.

Setup (on the calling machine):
    pip install openai

Run:
    # Local:
    python test_client.py
    # Remote (from another machine on the LAN):
    python test_client.py --base-url http://192.168.1.50:8080/v1 --api-key <key>

The API key is printed when you start the server (also stored in api-key.txt).
"""

import argparse
import os
from pathlib import Path

from openai import OpenAI


def default_api_key() -> str:
    # Convenience: when run on the host machine, read the generated key file.
    key_file = Path(__file__).with_name("api-key.txt")
    if key_file.exists():
        return key_file.read_text(encoding="ascii").strip()
    return os.environ.get("LLAMA_API_KEY", "CHANGE_ME")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://localhost:8080/v1")
    parser.add_argument("--api-key", default=default_api_key())
    parser.add_argument("--prompt", default="In one sentence, what is llama.cpp?")
    args = parser.parse_args()

    client = OpenAI(base_url=args.base_url, api_key=args.api_key)

    resp = client.chat.completions.create(
        model="gemma-4-E4B-it",
        messages=[{"role": "user", "content": args.prompt}],
        max_tokens=256,
        stream=False,
    )

    print("Assistant:\n" + resp.choices[0].message.content)


if __name__ == "__main__":
    main()
