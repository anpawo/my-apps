# Benchmark input: the heads of two large local Claude Code transcripts, kept out of git (they are my sessions).
import glob, os

D = os.path.dirname(os.path.abspath(__file__))
MAIN_BYTES, HOLDOUT_BYTES = 20_000_000, 8_000_000

files = sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")), key=os.path.getsize, reverse=True)
for name, path, size in (("head_main.bin", files[2], MAIN_BYTES), ("head_holdout.bin", files[5], HOLDOUT_BYTES)):
    data = open(path, "rb").read(size)
    open(f"{D}/{name}", "wb").write(data)
    print(name, len(data), "bytes")
