"""Resolve the shared Verilog -f lists so every tool compiles the same source set.

vcs-rtl/verilog_file_common.f and vcs-rtl/verilog_file_<target>.f are the only
places a source file is registered; the ModelSim helpers read them through
.tools/svfilelist.ps1 and the Python regressions read them through this module.
Entries are relative to the directory the simulator is started from (vcs-rtl), so
a nested "-f" resolves against its parent list.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
LIST_DIR = ROOT / 'vcs-rtl'


def _read(path, base):
    files, incdirs = [], []
    for raw in Path(path).read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('//') or line.startswith('#'):
            continue
        if line.startswith('-f '):
            sub_files, sub_incdirs = _read(base / line[3:].strip().strip('"\''), base)
            files += sub_files
            incdirs += sub_incdirs
        elif line.startswith('+incdir+'):
            for entry in line[len('+incdir+'):].split('+'):
                if entry.strip():
                    incdirs.append((base / entry.strip()).resolve())
        else:
            files.append((base / line.strip('"\'')).resolve())
    return files, incdirs


def targets():
    """Every per-testbench list; common and the aggregate are not targets."""
    names = (p.stem[len('verilog_file_'):] for p in LIST_DIR.glob('verilog_file_*.f'))
    return sorted(n for n in names if n not in ('common', 'pl'))


def compile_set(target):
    """Return (files, incdirs, top) for one target, as absolute paths."""
    path = LIST_DIR / f'verilog_file_{target}.f'
    if not path.is_file():
        raise SystemExit(f'unknown target {target}; known targets: {", ".join(targets())}')
    # _read already expands a nested "-f verilog_file_common.f", so incdirs holds
    # exactly the search path the simulator sees; verilog_file_macro.f omits common
    # on purpose and must not inherit its +incdir+ entries.
    files, incdirs = _read(path, LIST_DIR)
    tops = [f.stem for f in files if f.stem.startswith('tb_')]
    if not tops:
        raise SystemExit(f'target {target} declares no tb_* top module')
    return files, incdirs, tops[0]


def compile_union(targets_used):
    """Merge several targets, keeping first-seen order and dropping duplicates."""
    files = []
    for name in targets_used:
        for entry in compile_set(name)[0]:
            if entry not in files:
                files.append(entry)
    return files
