import os, re, subprocess, tempfile, json
D = os.path.dirname(os.path.abspath(__file__))
BANNED = [r"static\s+var", r"nonisolated\(unsafe\)", r"concurrentPerform", r"\bThread\b", r"\bTask\s*\{", r"\basync\b", r"^var\s", r"\blazy\b"]
COMPILE_TIMEOUT_S, RUN_TIMEOUT_S, REPS = 240, 60, 3
# My Mac queues every compiler run through build-stack; elsewhere swiftc runs directly.
BUILD_STACK = os.path.expanduser("~/.local/bin/build-stack")
COMPILE = [BUILD_STACK, "swiftc"] if os.path.exists(BUILD_STACK) else ["swiftc"]

def build(src, outdir):
    exe = os.path.join(outdir, "bench")
    r = subprocess.run([*COMPILE, "-O", src, os.path.join(D, "main.swift"), "-o", exe], capture_output=True, text=True, timeout=COMPILE_TIMEOUT_S)
    return (exe if r.returncode == 0 and os.path.exists(exe) else None), r.stderr[-1500:]

def run(exe, rules, prompts, outfile):
    r = subprocess.run([exe, rules, prompts, str(REPS), outfile], capture_output=True, text=True, timeout=RUN_TIMEOUT_S)
    if r.returncode != 0: return None
    return int(r.stdout.split()[0])

def measure(path):
    with tempfile.TemporaryDirectory() as t:
        exe, err = build(path, t)
        if not exe: return {"error": "compile: " + err}
        res = {}
        for tag in ("main", "holdout"):
            suffix = "" if tag == "main" else "_holdout"
            out = os.path.join(t, tag + ".txt")
            ns = run(exe, os.path.join(D, f"rules{suffix}.txt"), os.path.join(D, f"prompts{suffix}.txt"), out)
            if ns is None: return {"error": "run failed on " + tag}
            res[tag] = (ns, open(out).read())
        return res

def baseline():
    f = os.path.join(D, "baseline.json")
    if os.path.exists(f): return json.load(open(f))
    m = measure(os.path.join(D, "initial_program.swift"))
    b = {"main_ns": m["main"][0], "holdout_ns": m["holdout"][0], "main": m["main"][1], "holdout": m["holdout"][1]}
    json.dump(b, open(f, "w")); return b

def evaluate(program_path):
    code = open(program_path).read()
    block = code.split("EVOLVE-BLOCK-START")[-1].split("EVOLVE-BLOCK-END")[0]
    for p in BANNED:
        if re.search(p, block, re.M): return {"combined_score": 0.0, "correct": 0.0, "error": "banned: " + p}
    b = baseline()
    try: m = measure(program_path)
    except subprocess.TimeoutExpired: return {"combined_score": 0.0, "correct": 0.0, "error": "timeout"}
    if "error" in m: return {"combined_score": 0.0, "correct": 0.0, "error": m["error"]}
    if m["main"][1] != b["main"] or m["holdout"][1] != b["holdout"]:
        return {"combined_score": 0.0, "correct": 0.0, "error": "output differs from the original recall"}
    speed = b["main_ns"] / m["main"][0]
    return {"combined_score": speed, "correct": 1.0, "speedup": speed, "main_ms": m["main"][0] / 1e6}
