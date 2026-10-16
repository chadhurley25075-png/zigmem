#!/usr/bin/env python3
"""syscall profile of the server while it answers 150 searches (strace -c -f, attached by PID, detached after)."""
import os, random, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import gates as g
syl = ["ka", "lo", "mi", "ner", "tu", "sa", "vel", "dor", "pi", "qua", "ren", "zo", "bri", "fen", "gal", "hum"]
def word(idx):
    x = idx + 17; s = ""
    for _ in range(3):
        s += syl[x % 16]; x //= 16
    return s + str(idx % 97)
rng = random.Random(7)
qa = [" ".join(word(int(5000 * rng.random() ** 3)) for _ in range(2 + rng.randrange(2))) for _ in range(150)]
home = os.path.join(g.SCR, "lat")
tok = g.token_add(home, "probe3-" + str(int(time.time())), "syn-a,syn-b")
st = subprocess.Popen(["/usr/bin/time", "-v", "-o", os.path.join(g.SCR, "time_v.txt"), g.Z, "serve", "--home", home, "--port", "18158"], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
time.sleep(2)
t = time.perf_counter()
for q in qa:
    g.req(18158, "POST", "/v1/search/memories", {"query": q, "limit": 10}, tok)
print("150 queries under strace: %.2f s" % (time.perf_counter() - t))
srv = int(subprocess.run(["pgrep", "-P", str(st.pid)], capture_output=True, text=True).stdout.split()[0])
os.kill(srv, 15); st.wait(10)
print("server pid", srv, "gone:", not g.alive(srv), "strace gone:", not g.alive(st.pid))
print(open(os.path.join(g.SCR, "time_v.txt")).read())
