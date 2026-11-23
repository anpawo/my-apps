# Benchmark input from the ERRORS rule files VCX reads, kept out of git: they are my agents' private notes.
import os, random, re

HOME = os.path.expanduser("~")
D = os.path.dirname(os.path.abspath(__file__))
PROMPTS, HOLDOUT_PROMPTS = 400, 200

lines = []
for f in (f"{HOME}/.claude/ERRORS.md", f"{HOME}/.claude/ERRORS.tools.md"):
    lines += [l[2:] for l in open(f).read().split("\n") if l.startswith("- ")]
vocab = [w for l in lines for w in re.findall(r"[A-Za-z0-9]+", l)]
filler = "please can you fix the build then commit and push it also check the app window and the session".split()

def prompts(n, seed):
    r = random.Random(seed)
    return [" ".join(r.choice(vocab) if r.random() < 0.6 else r.choice(filler) for _ in range(r.randint(2, 25))) for _ in range(n)]

open(f"{D}/rules.txt", "w").write("\n".join(lines))
open(f"{D}/prompts.txt", "w").write("\n".join(prompts(PROMPTS, 1) + ["hi", "commit and push the git fix", "add a launch agent", ""]))
held = lines[:]
random.Random(7).shuffle(held)
open(f"{D}/rules_holdout.txt", "w").write("\n".join(held[: len(held) // 2]))
open(f"{D}/prompts_holdout.txt", "w").write("\n".join(prompts(HOLDOUT_PROMPTS, 2)))
print(len(lines), "rules")
