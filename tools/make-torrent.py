#!/usr/bin/env python3
"""Create a single-file .torrent (BEP 3) with web seeds (BEP 19) and print its magnet link.

Pure Python, no dependencies, so it runs on a box with nothing but python3.

    make-torrent.py FILE --out FILE.torrent --webseed URL [--webseed URL ...] [--tracker URL ...] [--piece-mib 4]

The torrent is deterministic for a given file, piece size, name, trackers and web seeds
(no creation date is written), so two people making it from the same file get the same infohash.
"""
import argparse
import hashlib
import os
import sys
import urllib.parse

DEFAULT_TRACKERS = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
]


def bencode(obj):
    if isinstance(obj, int):
        return b"i" + str(obj).encode() + b"e"
    if isinstance(obj, bytes):
        return str(len(obj)).encode() + b":" + obj
    if isinstance(obj, str):
        return bencode(obj.encode())
    if isinstance(obj, list):
        return b"l" + b"".join(bencode(x) for x in obj) + b"e"
    if isinstance(obj, dict):
        out = b"d"
        for k in sorted(obj):
            kb = k.encode() if isinstance(k, str) else k
            out += bencode(kb) + bencode(obj[k])
        return out + b"e"
    raise TypeError(type(obj))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--out", required=True)
    ap.add_argument("--webseed", action="append", default=[], help="HTTP(S) URL of the same file (BEP 19)")
    ap.add_argument("--tracker", action="append", default=None, help="announce URL (repeatable); default: 4 public trackers")
    ap.add_argument("--piece-mib", type=int, default=4)
    ap.add_argument("--name", default=None, help="file name inside the torrent (default: basename)")
    args = ap.parse_args()

    trackers = args.tracker if args.tracker is not None else DEFAULT_TRACKERS
    piece_len = args.piece_mib * 1024 * 1024
    size = os.path.getsize(args.file)
    name = args.name or os.path.basename(args.file)

    pieces = bytearray()
    sha = hashlib.sha256()
    done = 0
    with open(args.file, "rb") as f:
        while True:
            chunk = f.read(piece_len)
            if not chunk:
                break
            pieces += hashlib.sha1(chunk).digest()
            sha.update(chunk)
            done += len(chunk)
            print(f"\rhashing {done * 100 // size}%", end="", file=sys.stderr)
    print(file=sys.stderr)

    info = {"name": name, "length": size, "piece length": piece_len, "pieces": bytes(pieces)}
    meta = {"info": info}
    if trackers:
        meta["announce"] = trackers[0]
        meta["announce-list"] = [[t] for t in trackers]
    if args.webseed:
        meta["url-list"] = args.webseed if len(args.webseed) > 1 else args.webseed[0]

    infohash = hashlib.sha1(bencode(info)).hexdigest()
    with open(args.out, "wb") as f:
        f.write(bencode(meta))

    magnet = f"magnet:?xt=urn:btih:{infohash}&dn={urllib.parse.quote(name)}"
    for t in trackers:
        magnet += "&tr=" + urllib.parse.quote(t, safe="")
    for u in args.webseed:
        magnet += "&ws=" + urllib.parse.quote(u, safe="")

    print(f"file      {name}")
    print(f"size      {size}")
    print(f"sha256    {sha.hexdigest()}")
    print(f"infohash  {infohash}")
    print(f"pieces    {len(pieces) // 20} x {args.piece_mib} MiB")
    print(f"torrent   {args.out}")
    print(f"magnet    {magnet}")


if __name__ == "__main__":
    main()
