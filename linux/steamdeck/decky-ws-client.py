#!/usr/bin/env python3
"""Small Decky Loader websocket client for PhaseZero automation."""
import argparse
import asyncio
import json
import sys

import aiohttp


CALL = 0
REPLY = 1
EVENT = 3


async def call_route(ws, call_id, route, args):
    await ws.send_json({"type": CALL, "id": call_id, "route": route, "args": args})


async def install_plugin(base_url, artifact, name, version, digest, timeout):
    async with aiohttp.ClientSession() as session:
        async with session.get(f"{base_url}/auth/token") as response:
            response.raise_for_status()
            token = await response.text()

        async with session.ws_connect(f"{base_url}/ws?auth={token}") as ws:
            await call_route(ws, 1, "utilities/install_plugin", [artifact, name, version, digest, 1])
            request_id = None
            install_reply = False
            confirm_sent = False

            async def wait_messages():
                nonlocal request_id, install_reply, confirm_sent
                async for msg in ws:
                    if msg.type != aiohttp.WSMsgType.TEXT:
                        continue
                    data = json.loads(msg.data)
                    if data.get("type") == EVENT and data.get("event") == "loader/add_plugin_install_prompt":
                        args = data.get("args", [])
                        if len(args) >= 3 and args[0] == name:
                            request_id = str(args[2])
                            await call_route(ws, 2, "utilities/confirm_plugin_install", [request_id])
                            confirm_sent = True
                    elif data.get("type") == REPLY and data.get("id") == 2:
                        install_reply = True
                        return
                    elif data.get("type") == REPLY and data.get("id") == 1 and request_id is not None and not confirm_sent:
                        await call_route(ws, 2, "utilities/confirm_plugin_install", [request_id])
                        confirm_sent = True
                    elif data.get("type") == -1:
                        raise RuntimeError(json.dumps(data.get("error", data), ensure_ascii=False))

            await asyncio.wait_for(wait_messages(), timeout=timeout)
            if not install_reply:
                raise RuntimeError(f"Decky install did not finish for {name}")


async def get_plugins(base_url, timeout):
    async with aiohttp.ClientSession() as session:
        async with session.get(f"{base_url}/auth/token") as response:
            response.raise_for_status()
            token = await response.text()

        async with session.ws_connect(f"{base_url}/ws?auth={token}") as ws:
            await call_route(ws, 1, "loader/get_plugins", [])
            async def wait_reply():
                async for msg in ws:
                    if msg.type != aiohttp.WSMsgType.TEXT:
                        continue
                    data = json.loads(msg.data)
                    if data.get("type") == REPLY and data.get("id") == 1:
                        print(json.dumps(data.get("result", []), ensure_ascii=False))
                        return
                    if data.get("type") == -1:
                        raise RuntimeError(json.dumps(data.get("error", data), ensure_ascii=False))
            await asyncio.wait_for(wait_reply(), timeout=timeout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:1337")
    parser.add_argument("--timeout", type=int, default=240)
    sub = parser.add_subparsers(dest="command", required=True)

    install = sub.add_parser("install-plugin")
    install.add_argument("--artifact", required=True)
    install.add_argument("--name", required=True)
    install.add_argument("--version", required=True)
    install.add_argument("--hash", required=True)

    sub.add_parser("get-plugins")
    args = parser.parse_args()

    try:
        if args.command == "install-plugin":
            asyncio.run(install_plugin(args.base_url, args.artifact, args.name, args.version, args.hash, args.timeout))
        elif args.command == "get-plugins":
            asyncio.run(get_plugins(args.base_url, args.timeout))
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
