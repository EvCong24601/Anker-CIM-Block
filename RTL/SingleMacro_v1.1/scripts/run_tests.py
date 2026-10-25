"""Compile and simulate the actual SystemVerilog RTL with Icarus Verilog.

No downloads or global installations. Pass --iverilog/--vvp when not in PATH.
Run from any directory; build outputs are kept under this project.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TOOL_ENV = os.environ.copy()
NEGATIVE = {
    "precision": "illegal precision/phase",
    "phase": "illegal precision/phase",
    "hold_invalid": "reuse invalid hold",
    "uninitialized": "read uninitialized row",
    "hold_address": "reuse address mismatch",
    "hold_address_pending": "reuse address mismatch",
    "unknown_write": "unknown write input",
    "unknown_activation": "unknown compute input",
    "unknown_control": "unknown compute input",
    "read_write": "simultaneous read/write",
    "write_busy": "write before pipeline drain",
    "hold_after_write": "reuse invalid hold",
    "hold_after_reset": "reuse invalid hold",
}


def resolve_tool(value: str, name: str) -> str:
    resolved = shutil.which(value)
    if resolved:
        return str(Path(resolved).resolve())
    candidate = Path(value)
    if candidate.is_file():
        return str(candidate.resolve())
    raise SystemExit(f"{name} not found: provide --{name} /absolute/path/to/{name}")


def run(command: list[str], log: Path) -> subprocess.CompletedProcess[str]:
    # The Windows MSYS2 build crashes with an inherited NUL stdin. Supply an
    # actual pipe (closed after an empty input), including for the compiler.
    result = subprocess.run(command, cwd=ROOT, input="", capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=600, env=TOOL_ENV)
    log.write_text("COMMAND: " + repr(command) + "\n" + result.stdout + result.stderr,
                   encoding="utf-8")
    return result


def checked_compile(command: list[str], log: Path) -> None:
    result = run(command, log)
    if result.returncode:
        lines = (result.stdout + result.stderr).splitlines()
        if len(lines) > 40:
            lines = lines[:8] + ["... full diagnostics in log ..."] + lines[-24:]
        print("\n".join(lines))
        raise SystemExit(f"Compile failed; see {log}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--jobs", type=int, default=4, help="Parallel simulation processes (default 4)")
    args = parser.parse_args()
    iv = resolve_tool(args.iverilog, "iverilog")
    vvp = resolve_tool(args.vvp, "vvp")
    # Child ivl.exe/VPI modules also need project-local runtime DLLs. This PATH
    # only applies to the spawned tools, never to the user's global environment.
    tool_dirs = dict.fromkeys((str(Path(iv).parent), str(Path(vvp).parent)))
    TOOL_ENV["PATH"] = os.pathsep.join(tool_dirs) + os.pathsep + TOOL_ENV.get("PATH", "")
    compiler = [iv]
    relocated_lib = Path(iv).parent.parent / "lib" / "ivl"
    if relocated_lib.is_dir():
        compiler.extend(["-B", str(relocated_lib)])
    runtime = [vvp]
    if relocated_lib.is_dir():
        runtime.extend(["-M", str(relocated_lib)])
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    summary: dict[str, object] = {"spec_version": "v1.1", "phase_latency": 1,
                                "baseline_trace_comparison": True,
                                "positive": [], "negative": [], "synthesis_elaboration": False}
    version = run(compiler + ["-V"], build / "iverilog_version.log")
    version_lines = (version.stdout or version.stderr).splitlines()
    summary["tool"] = next((line for line in version_lines if "Icarus Verilog version" in line), "unknown")
    # Check the synthesizable source branch independently of testbench/checkers.
    checked_compile(compiler + ["-g2012", "-Wall", "-DSYNTHESIS", "-s", "SingleMacro",
                     "-o", str(build / "synthesis_branch.vvp"), "-f", "rtl/filelist.f"],
                    build / "synthesis_compile.log")
    summary["synthesis_elaboration"] = True
    arithmetic = build / "tb_arithmetic.vvp"
    checked_compile(compiler + ["-g2012", "-Wall", "-s", "tb_MacroArithmetic",
                    "-o", str(arithmetic), "-f", "rtl/filelist.f", "tb/tb_MacroArithmetic.sv"],
                    build / "compile_arithmetic.log")
    arithmetic_result = run(runtime + [str(arithmetic)], build / "arithmetic.log")
    if arithmetic_result.returncode or "PASS arithmetic" not in arithmetic_result.stdout:
        raise SystemExit(arithmetic_result.stdout + arithmetic_result.stderr)
    summary["arithmetic"] = arithmetic_result.stdout.strip()
    print(arithmetic_result.stdout.strip(), flush=True)
    outputs = {}
    for gating in (0, 1):
        output = build / f"tb_gating{gating}.vvp"
        checked_compile(compiler + ["-g2012", "-Wall", "-DSINGLE_MACRO_ASSERTIONS",
                         "-s", "tb_SingleMacro", f"-Ptb_SingleMacro.CLOCK_GATING={gating}",
                         "-o", str(output), "-f", "tb/filelist.f"],
                        build / f"compile_gating{gating}.log")
        outputs[gating] = output

    def positive(gating: int, seed: int) -> dict[str, object]:
        output = outputs[gating]
        result = run(runtime + [str(output), f"+SEED={seed}"],
                     build / f"positive_gating{gating}_seed{seed}.log")
        text = result.stdout + result.stderr
        if result.returncode or "PASS " not in text:
            print(text)
            raise SystemExit("RTL regression failed")
        counts = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", text)}
        return {"clock_gating": gating, "seed": seed, "counts": counts, "result": text.strip()}

    def negative(test: str, diagnostic: str) -> dict[str, str]:
        result = run(runtime + [str(outputs[1]), f"+NEGATIVE={test}"], build / f"negative_{test}.log")
        text = result.stdout + result.stderr
        if result.returncode == 0 or f"SM_PROTOCOL: {diagnostic}" not in text:
            print(text)
            raise SystemExit(f"Negative protocol test failed: {test}")
        return {"case": test, "diagnostic": diagnostic}

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = {pool.submit(positive, gating, seed): "positive"
                   for gating in (0, 1) for seed in (324508639, 20261013)}
        futures.update({pool.submit(negative, test, diagnostic): "negative"
                        for test, diagnostic in NEGATIVE.items()})
        for future in as_completed(futures):
            kind = futures[future]
            entry = future.result()
            summary[kind].append(entry)
            print(entry["result"] if kind == "positive" else
                  f"PASS expected protocol rejection: {entry['case']}", flush=True)
    summary["positive"].sort(key=lambda item: (item["clock_gating"], item["seed"]))
    summary["negative"].sort(key=lambda item: item["case"])
    (build / "results.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n",
                                         encoding="utf-8")
    print(f"All checks passed; summary: {build / 'results.json'}")


if __name__ == "__main__":
    main()
