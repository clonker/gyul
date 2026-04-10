#!/usr/bin/env python3
"""
Differential test runner: drives gyul against Solidity's
`libsolidity/semanticTests/` corpus.

For each `*.sol` file:
  1. Parse the trailing `// ----` block into a deploy + call sequence.
  2. Skip files we know we can't run (multi-contract, library tests,
     ABI features we don't model, etc.) — see SKIP_RULES.
  3. Compile the source to Yul via `solc --ir --optimize`.
  4. ABI-encode constructor args and each call.
  5. Run `gyul --quiet ... <file>` once and parse the per-line output.
  6. Compare against expected returns.

Usage:
    scripts/semantictests.py [--solc PATH] [--gyul PATH]
                              [--root PATH] [--filter SUBSTR]
                              [--limit N] [--verbose]

Defaults assume the script is run from the repo root.

The runner is intentionally lenient: anything we can't parse or that
needs an unsupported solc feature counts as SKIP, not FAIL. The goal
is to find bugs in `gyul`, not to chase 100% coverage.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# ── ABI encoding helpers ────────────────────────────────────────────────

def selector(signature: str) -> bytes:
    """First 4 bytes of keccak256(signature)."""
    # Solidity uses keccak-256, not the FIPS-202 SHA-3 variant. Use
    # pycryptodome if available, else fall back to a vendored impl.
    try:
        from Crypto.Hash import keccak  # type: ignore
        h = keccak.new(digest_bits=256)
        h.update(signature.encode())
        return h.digest()[:4]
    except ImportError:
        return _keccak256(signature.encode())[:4]


def _keccak256(data: bytes) -> bytes:
    """Pure-Python Keccak-256 fallback when pycryptodome isn't installed."""
    rate = 136
    out_bytes = 32

    def rol(x: int, n: int) -> int:
        return ((x << n) | (x >> (64 - n))) & 0xFFFFFFFFFFFFFFFF

    rc = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A,
        0x8000000080008000, 0x000000000000808B, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009, 0x000000000000008A,
        0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
        0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
        0x000000000000800A, 0x800000008000000A, 0x8000000080008081,
        0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    rotc = [
        0,  1, 62, 28, 27, 36, 44,  6, 55, 20,  3, 10,
        43, 25, 39, 41, 45, 15, 21,  8, 18,  2, 61, 56, 14,
    ]
    pi = [
        10,  7, 11, 17, 18,  3,  5, 16,  8, 21, 24,  4,
        15, 23, 19, 13, 12,  2, 20, 14, 22,  9,  6,  1,
    ]

    def f1600(state: list[int]) -> None:
        for r in range(24):
            bc = [state[i] ^ state[i + 5] ^ state[i + 10] ^ state[i + 15] ^ state[i + 20] for i in range(5)]
            for i in range(5):
                t = bc[(i + 4) % 5] ^ rol(bc[(i + 1) % 5], 1)
                for j in range(0, 25, 5):
                    state[j + i] ^= t
            t = state[1]
            for i in range(24):
                j = pi[i]
                bc[0] = state[j]
                state[j] = rol(t, rotc[i + 1])
                t = bc[0]
            for j in range(0, 25, 5):
                bc = state[j:j + 5]
                for i in range(5):
                    state[j + i] = bc[i] ^ ((~bc[(i + 1) % 5]) & bc[(i + 2) % 5]) & 0xFFFFFFFFFFFFFFFF
            state[0] ^= rc[r]

    state = [0] * 25
    pad = bytearray(data)
    pad += b"\x01"
    while len(pad) % rate != 0:
        pad.append(0)
    pad[-1] |= 0x80
    for block_start in range(0, len(pad), rate):
        for i in range(rate // 8):
            v = int.from_bytes(pad[block_start + i * 8: block_start + i * 8 + 8], "little")
            state[i] ^= v
        f1600(state)
    out = bytearray()
    while len(out) < out_bytes:
        for i in range(rate // 8):
            out += state[i].to_bytes(8, "little")
            if len(out) >= out_bytes:
                break
        if len(out) < out_bytes:
            f1600(state)
    return bytes(out[:out_bytes])


def encode_uint(value: int) -> bytes:
    """ABI-encode an unsigned int as 32 BE bytes (zero-padded)."""
    if value < 0:
        value = (1 << 256) + value
    return value.to_bytes(32, "big", signed=False)


def encode_int(value: int) -> bytes:
    if value < 0:
        value = (1 << 256) + value
    return value.to_bytes(32, "big", signed=False)


def encode_bool(value: bool) -> bytes:
    return (1 if value else 0).to_bytes(32, "big")


def encode_address(value: int) -> bytes:
    return value.to_bytes(32, "big", signed=False)


def encode_arg(arg_type: str, raw: str) -> bytes:
    """Encode a single ABI value. Returns the 32-byte head only — we
    don't model dynamic types yet (those count as SKIP at parse time)."""
    raw = raw.strip()
    if arg_type == "bool":
        # isoltest uses any of: true, false, 0, 1, 0x0, 0x1.
        if raw in ("true", "1") or raw.startswith("0x") and int(raw, 16) != 0:
            return encode_bool(True)
        return encode_bool(False)
    if arg_type.startswith("uint"):
        return encode_uint(_parse_int(raw))
    if arg_type.startswith("int"):
        return encode_int(_parse_int(raw))
    if arg_type == "address":
        return encode_address(_parse_int(raw))
    if arg_type.startswith("bytes") and arg_type != "bytes":
        # bytesN: left-aligned in 32 bytes
        if raw.startswith('"') and raw.endswith('"'):
            payload = raw[1:-1].encode()
        else:
            payload = bytes.fromhex(raw[2:] if raw.startswith("0x") else raw)
        return payload + b"\x00" * (32 - len(payload))
    raise ValueError(f"unsupported abi type: {arg_type}")


def _parse_int(s: str) -> int:
    s = s.strip()
    if s.startswith("0x") or s.startswith("-0x"):
        return int(s, 16)
    return int(s)


# ── Test format parsing ────────────────────────────────────────────────

@dataclasses.dataclass
class CallStep:
    """One line in the test expectation block."""
    func_name: str | None  # None = constructor
    arg_types: list[str]
    arg_values: list[str]
    value: int = 0  # wei
    expect_revert: bool = False
    expect_return_hex: str | None = None  # hex with 0x prefix, or None

    def signature(self) -> str:
        return f"{self.func_name}({','.join(self.arg_types)})"


@dataclasses.dataclass
class TestSpec:
    path: Path
    constructor: CallStep | None
    calls: list[CallStep]
    skip_reason: str | None = None


NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*")


def parse_step(line: str) -> CallStep | None:
    """Parse one expectation line. Test format examples:
       // f() -> 1
       // constructor(): 1, 2, 3, 4 ->
       // constructor(), 27 wei ->
       // constructor(), 2 wei: 3 ->
       // x(uint256): 0x42 -> 100
       // g(int8,int8): -10, 3 -> -1
       // setName(): "alice" -> FAILURE, hex"4e487b71", 0x12

    The grammar:
       NAME '(' TYPES ')' [',' INT 'wei'] [':' ARGS] '->' RETS
    """
    line = line.rstrip()
    if not line.startswith("//"):
        return None
    body = line[2:].strip()
    if not body:
        return None
    if body.startswith(("gas ", "gas:")):
        return None
    if body.startswith(("~", "library:", "compileToEwasm:", "EVMVersion:")):
        return None
    if body.startswith("---") or body.startswith("==="):
        return None

    # Side-effect-only calls sometimes omit the trailing `->` (e.g.
    # `// update(uint256): 4`). Treat the entire body as the LHS in
    # that case, with an empty RHS (no expected return).
    if "->" not in body:
        lhs = body.strip()
        rhs = ""
    else:
        lhs, _, rhs = body.partition("->")
        lhs = lhs.strip()
        rhs = rhs.strip()

    # Match the function name + types.
    m = NAME_RE.match(lhs)
    if not m:
        return None
    name = m.group(0)
    rest = lhs[len(name):].lstrip()
    if not rest.startswith("("):
        # Likely a balance/storage/account directive — skip silently.
        return None

    # Find the matching `)`.
    depth = 1
    end = 1
    while end < len(rest) and depth > 0:
        if rest[end] == "(":
            depth += 1
        elif rest[end] == ")":
            depth -= 1
        end += 1
    if depth != 0:
        return None
    types_inner = rest[1:end - 1].strip()
    rest = rest[end:].lstrip()

    arg_types = [t.strip() for t in types_inner.split(",")] if types_inner else []

    value = 0
    arg_values: list[str] = []

    while rest:
        if rest.startswith(","):
            # `, <int> wei`
            rest = rest[1:].lstrip()
            wei_m = re.match(r"^([\-0-9xa-fA-F]+)\s*wei", rest)
            if wei_m:
                value = _parse_int(wei_m.group(1))
                rest = rest[wei_m.end():].lstrip()
            else:
                return None
        elif rest.startswith(":"):
            # `: <args>`. Args may include strings with `,` so split safely.
            rest = rest[1:].lstrip()
            arg_values = [v.strip() for v in _split_top_level(rest)]
            rest = ""
        else:
            return None

    is_constructor = name == "constructor"
    func_name = None if is_constructor else name

    expect_revert = False
    expect_return_hex: str | None = None
    if rhs.startswith("FAILURE"):
        expect_revert = True
    elif rhs:
        try:
            return_words: list[bytes] = []
            for piece in _split_top_level(rhs):
                piece = piece.strip()
                if piece.startswith('"') and piece.endswith('"'):
                    s = piece[1:-1].encode()
                    return_words.append(s + b"\x00" * (32 - len(s)))
                elif piece.startswith("hex\""):
                    inner = piece[len("hex\""):-1]
                    return_words.append(bytes.fromhex(inner))
                elif piece in ("true", "false"):
                    return_words.append(encode_bool(piece == "true"))
                else:
                    return_words.append(encode_int(_parse_int(piece)))
            expect_return_hex = "0x" + b"".join(return_words).hex()
        except Exception:
            return None
    else:
        # Empty RHS = side-effect-only call.
        expect_return_hex = ""

    # isoltest annotations write constructors with empty type lists
    # (`constructor(): 3 ->`); the types are inferred from the contract.
    # We default each missing arg to uint256 — correct for the common
    # case and detected as a parse failure for everything else.
    if is_constructor and not arg_types and arg_values:
        arg_types = ["uint256"] * len(arg_values)

    if len(arg_types) != len(arg_values):
        return None

    return CallStep(
        func_name=func_name,
        arg_types=arg_types,
        arg_values=arg_values,
        value=value,
        expect_revert=expect_revert,
        expect_return_hex=expect_return_hex,
    )


def _split_top_level(s: str) -> list[str]:
    """Split on commas not inside (), [], or "...".
    Used for return-value lists like `1, 2, hex"abcd"`."""
    out = []
    depth = 0
    in_str = False
    cur = []
    for ch in s:
        if in_str:
            cur.append(ch)
            if ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            cur.append(ch)
            continue
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur))
    return out


def parse_test_file(path: Path) -> TestSpec:
    text = path.read_text()
    lines = text.splitlines()
    try:
        marker = next(i for i, l in enumerate(lines) if l.strip() == "// ----")
    except StopIteration:
        return TestSpec(path=path, constructor=None, calls=[], skip_reason="no `// ----` block")

    expectations = lines[marker + 1:]
    steps: list[CallStep] = []
    for line in expectations:
        step = parse_step(line)
        if step is None:
            continue
        steps.append(step)

    constructor: CallStep | None = None
    calls: list[CallStep] = []
    for s in steps:
        if s.func_name is None:
            constructor = s
        else:
            calls.append(s)

    return TestSpec(path=path, constructor=constructor, calls=calls)


# ── Skip rules ──────────────────────────────────────────────────────────

SKIP_DYNAMIC_TYPES = ("string", "bytes", "[]", "[")  # dynamic ABI we don't encode

# Cap per-call arg sizes when the source has obvious loops. Without
# gas metering, a loop bound > ~100 quickly blows our 2s budget.
LOOP_BAIT_THRESHOLD = 64
LOOP_PATTERNS = ("for ", "for(", "while ", "while(", ".push(", ".pop(", "do {", "do{")

def has_loop(source: str) -> bool:
    return any(p in source for p in LOOP_PATTERNS)


def determine_skip(spec: TestSpec, source: str) -> str | None:
    if spec.skip_reason:
        return spec.skip_reason
    if "library " in source:
        return "library tests need linker support"
    if "interface " in source and "contract " not in source:
        return "interface-only file"
    if source.count("contract ") > 1:
        return "multi-contract source"
    if not spec.calls and not spec.constructor:
        return "no expectation lines"
    # Tests that explicitly expect an out-of-gas FAILURE depend on
    # gas metering. We don't have that, so skip them rather than
    # blow the per-test budget running tens of thousands of loop
    # iterations.
    if "Out-of-gas" in source or "Out of gas" in source or "out-of-gas" in source.lower():
        return "depends on gas metering (FAILURE # Out of gas #)"

    def has_dynamic(types: list[str]) -> bool:
        return any(any(d in t for d in SKIP_DYNAMIC_TYPES) for t in types)

    if spec.constructor and has_dynamic(spec.constructor.arg_types):
        return "dynamic types in constructor"
    for c in spec.calls:
        if has_dynamic(c.arg_types):
            return "dynamic types in call"

    return None


# ── Driver ────────────────────────────────────────────────────────────

@dataclasses.dataclass
class RunResult:
    status: str  # "PASS", "FAIL", "SKIP", "ERROR"
    detail: str = ""


def encode_call(step: CallStep) -> str:
    """Hex-encode a function-call payload (selector + args)."""
    if step.func_name is None:
        # Constructor: just concat args, no selector.
        return "".join(encode_arg(t, v).hex() for t, v in zip(step.arg_types, step.arg_values))
    sel = selector(step.signature())
    body = b"".join(encode_arg(t, v) for t, v in zip(step.arg_types, step.arg_values))
    return (sel + body).hex()


def run_test(spec: TestSpec, source_path: Path, solc: Path, gyul: Path) -> RunResult:
    skip = determine_skip(spec, source_path.read_text())
    if skip:
        return RunResult("SKIP", skip)

    # 1. Compile to Yul IR.
    try:
        proc = subprocess.run(
            [str(solc), "--ir", "--optimize", str(source_path)],
            capture_output=True, text=True, timeout=30,
        )
    except subprocess.TimeoutExpired:
        return RunResult("SKIP", "solc timeout")
    if proc.returncode != 0:
        return RunResult("SKIP", f"solc error: {proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else 'unknown'}")

    # Extract just the `object "..." { ... }` block.
    out = proc.stdout
    obj_start = out.find("\nobject \"")
    if obj_start == -1:
        return RunResult("SKIP", "no object in solc output")
    yul = out[obj_start + 1:]

    # 2. Build the gyul invocation.
    args: list[str] = [str(gyul), "--quiet"]
    ctor_args_hex = ""
    if spec.constructor and spec.constructor.arg_values:
        try:
            ctor_args_hex = encode_call(spec.constructor)
        except Exception as e:
            return RunResult("SKIP", f"ctor encode: {e}")
    if ctor_args_hex:
        args += ["--ctor-args", "0x" + ctor_args_hex]
    if spec.constructor and spec.constructor.value:
        args += ["--value", str(spec.constructor.value)]
    for call in spec.calls:
        try:
            args += ["--call", "0x" + encode_call(call)]
        except Exception as e:
            return RunResult("SKIP", f"call encode: {e}")

    # Write the Yul to a temp file so the CLI can parse it from disk.
    with tempfile.NamedTemporaryFile("w", suffix=".yul", delete=False) as f:
        f.write(yul)
        yul_path = f.name
    args.append(yul_path)

    try:
        # Each test should complete in well under a second. Anything
        # slower is a real gyul bug (infinite loop, quadratic blowup,
        # leaked allocator) — fail loudly so we find it.
        proc = subprocess.run(args, capture_output=True, text=True, timeout=2)
    except subprocess.TimeoutExpired:
        # Don't unlink — leave the fixture on disk so we can debug it.
        return RunResult("FAIL", f"gyul timeout (>2s, fixture: {yul_path})")
    try:
        os.unlink(yul_path)
    except FileNotFoundError:
        pass

    if proc.returncode != 0:
        return RunResult("ERROR", f"gyul exit {proc.returncode}: {proc.stderr.strip()[:200]}")

    # 3. Parse the gyul output.
    output_lines = [l.strip() for l in proc.stdout.splitlines() if l.strip()]
    if not output_lines:
        return RunResult("ERROR", "no output")
    if not output_lines[0].startswith("DEPLOY"):
        return RunResult("ERROR", f"missing DEPLOY line: {output_lines[0]}")
    deploy_status = output_lines[0]
    call_lines = output_lines[1:]

    if deploy_status.startswith("DEPLOY REVERT"):
        if spec.constructor and spec.constructor.expect_revert:
            return RunResult("PASS", "expected ctor revert")
        return RunResult("FAIL", f"deploy reverted: {deploy_status}")

    if len(call_lines) != len(spec.calls):
        return RunResult("FAIL", f"call count mismatch: got {len(call_lines)}, expected {len(spec.calls)}")

    for i, (got, expected) in enumerate(zip(call_lines, spec.calls)):
        diff = compare_call(got, expected)
        if diff is not None:
            return RunResult("FAIL", f"call[{i}] {expected.signature()}: {diff}")

    return RunResult("PASS")


def compare_call(line: str, expected: CallStep) -> str | None:
    """Return None on match, or a string describing the diff."""
    line = line.strip()
    if line.startswith("CALL REVERT"):
        if expected.expect_revert:
            return None
        return f"got revert, expected {expected.expect_return_hex or '<no return>'}"
    if not line.startswith("CALL OK"):
        return f"unparseable: {line}"
    rest = line[len("CALL OK"):].strip()
    got_hex = rest if rest.startswith("0x") else "0x"
    if expected.expect_revert:
        return f"got success, expected revert"
    if expected.expect_return_hex is None or expected.expect_return_hex in ("0x", ""):
        # Side-effect-only call: anything goes (some solc-emitted runtimes
        # return a 0-length tuple even for void functions).
        return None
    if got_hex.lower() != expected.expect_return_hex.lower():
        return f"return mismatch: got {got_hex} expected {expected.expect_return_hex}"
    return None


# ── Main ──────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--solc", default="/home/mho/dev/gh/solidity/build/solc/solc")
    ap.add_argument("--gyul", default="./zig-out/bin/gyul")
    ap.add_argument("--root", default="vendor/solidity/test/libsolidity/semanticTests")
    ap.add_argument("--filter", default="", help="only run paths containing this substring")
    ap.add_argument("--limit", type=int, default=0, help="stop after N tests (0 = no limit)")
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--show-skips", action="store_true")
    args = ap.parse_args()

    solc = Path(args.solc)
    gyul = Path(args.gyul)
    root = Path(args.root)
    if not solc.exists():
        print(f"solc not found at {solc}", file=sys.stderr)
        return 2
    if not gyul.exists():
        print(f"gyul not found at {gyul}", file=sys.stderr)
        return 2
    if not root.exists():
        print(f"semanticTests root not found at {root}", file=sys.stderr)
        return 2

    paths = sorted(root.rglob("*.sol"))
    if args.filter:
        paths = [p for p in paths if args.filter in str(p)]

    counts: dict[str, int] = {"PASS": 0, "FAIL": 0, "SKIP": 0, "ERROR": 0}
    fails: list[tuple[Path, RunResult]] = []
    skips_by_reason: dict[str, int] = {}

    total = len(paths)
    for idx, path in enumerate(paths, 1):
        if args.limit and counts["PASS"] + counts["FAIL"] + counts["ERROR"] >= args.limit:
            break
        # Live progress on stderr — overwrites itself with \r so the
        # output stays compact unless the terminal is non-interactive.
        sys.stderr.write(
            f"\r[{idx}/{total}] pass={counts['PASS']} fail={counts['FAIL']} "
            f"err={counts['ERROR']} skip={counts['SKIP']}  {path.name[:50]:<50}"
        )
        sys.stderr.flush()
        spec = parse_test_file(path)
        result = run_test(spec, path, solc, gyul)
        counts[result.status] += 1
        if result.status == "FAIL":
            fails.append((path, result))
            if args.verbose:
                print(f"FAIL {path}: {result.detail}")
        elif result.status == "ERROR":
            fails.append((path, result))
            if args.verbose:
                print(f"ERROR {path}: {result.detail}")
        elif result.status == "SKIP":
            skips_by_reason[result.detail] = skips_by_reason.get(result.detail, 0) + 1
            if args.verbose and args.show_skips:
                print(f"SKIP {path}: {result.detail}")
        elif args.verbose:
            print(f"PASS {path}")

    sys.stderr.write("\n")
    print()
    print(f"== Summary ==")
    total = sum(counts.values())
    print(f"  total:   {total}")
    print(f"  pass:    {counts['PASS']}")
    print(f"  fail:    {counts['FAIL']}")
    print(f"  error:   {counts['ERROR']}")
    print(f"  skip:    {counts['SKIP']}")

    if args.show_skips and skips_by_reason:
        print()
        print("Skip reasons:")
        for reason, n in sorted(skips_by_reason.items(), key=lambda kv: -kv[1])[:15]:
            print(f"  {n:5}  {reason}")

    if fails and not args.verbose:
        print()
        print("First few failures:")
        for path, r in fails[:10]:
            print(f"  {r.status} {path}: {r.detail}")

    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
