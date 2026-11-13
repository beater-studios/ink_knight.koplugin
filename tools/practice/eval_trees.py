"""Works out, with Stockfish, the moves the reader can play in the practice chapters Lichess judges by an evaluation
("reach +2 in 3 moves", "equalize in 2"), and the opponent's answer to each, as the app judges them
(practice_goal.dart, practice_comment.dart): a move that is a mistake or a blunder fails, and after the reader's
moves are spent the evaluation must be past the target, or level. The plugin carries the result, so the Kindle never
has to search.

Usage: python3 -I tools/practice/eval_trees.py <practice.json> <stockfish> <output.json> [chapter id ...]
Each search is single threaded, with a fixed number of nodes and the hash cleared, so the same Stockfish gives the
same trees. The output is kept in the repository (tools/practice/eval_trees.json) and read by build.lua.
"""
import json
import math
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor

NODES_ALL = 3_000_000
NODES_ONE = 1_500_000
# Explored moves of each position, best first; the other acceptable ones are let try again on the device.
MAX_EXPLORED = 3
MAX_POSITIONS = 400
# How close to the target a score must be for the move to get a search of its own.
NEAR = 100
# Chapters whose target sits so close to the score of the solution that the last move needs a deeper search: Double
# Check #5 asks for +10, and the line of Tal's game ends near +10.7.
NODES_LAST = {"e7fu1G8T": 12_000_000}

GOOD, INACCURACY = 0.05, 0.11
WINNING = 0.5


def raw_chances(cp):
    return 2 / (1 + math.exp(-0.00368208 * cp)) - 1


def chances(score):
    kind, value = score
    if kind == "mate":
        cp = (21 - min(10, abs(value))) * 100
        return raw_chances(cp if value > 0 else -cp)
    return raw_chances(max(-1000, min(1000, value)))


def is_failure(before, after, is_best):
    """Whether the app calls the move a mistake or a blunder (MoveVerdict.fromShift)."""
    shift = before - after
    if is_best or shift < GOOD:
        return False
    if before >= WINNING and after >= WINNING:
        return False
    return shift >= INACCURACY


class Engine:
    def __init__(self, path):
        self.proc = subprocess.Popen([path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.send("uci")
        self.wait("uciok")
        self.send("setoption name Threads value 1")
        self.send("setoption name Hash value 64")
        self.ready()

    def send(self, line):
        self.proc.stdin.write(line + "\n")

    def wait(self, prefix):
        lines = []
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("stockfish stopped")
            line = line.rstrip("\n")
            lines.append(line)
            if line.startswith(prefix):
                return lines

    def ready(self):
        self.send("isready")
        self.wait("readyok")

    def name(self):
        self.send("uci")
        for line in self.wait("uciok"):
            if line.startswith("id name "):
                return line[8:]
        return "Stockfish"

    def board(self, fen, moves=()):
        """The FEN after moves, its legal moves and whether the side to move is in check."""
        self.send("position fen " + fen + (" moves " + " ".join(moves) if moves else ""))
        self.send("d")
        lines = self.wait("Checkers:")
        new_fen = next(line[5:] for line in lines if line.startswith("Fen: "))
        in_check = lines[-1].strip() != "Checkers:"
        self.send("go perft 1")
        legal = [line.split(":")[0] for line in self.wait("Nodes searched") if ": 1" in line and len(line.split(":")[0]) in (4, 5)]
        return new_fen, legal, in_check

    def analyse(self, fen, lines, nodes):
        """[(move, score)] best first, score ("cp", n) or ("mate", n) for the side to move."""
        self.send("ucinewgame")
        self.send("setoption name MultiPV value %d" % lines)
        self.ready()
        self.send("position fen " + fen)
        self.send("go nodes %d" % nodes)
        best = {}
        for line in self.wait("bestmove"):
            parts = line.split()
            if not parts or parts[0] != "info" or "pv" not in parts or "score" not in parts or "multipv" not in parts:
                continue
            if "lowerbound" in parts or "upperbound" in parts:
                continue
            index = int(parts[parts.index("multipv") + 1])
            at = parts.index("score")
            best[index] = (parts[parts.index("pv") + 1], (parts[at + 1], int(parts[at + 2])))
        return [best[i] for i in sorted(best)]


def white_cp(score, player):
    kind, value = score
    cp = (99999 if value > 0 else -99999) if kind == "mate" else value
    return cp if player == "w" else -cp


def is_level(score):
    return score[0] == "cp" and abs(score[1]) < 150


class Chapter:
    def __init__(self, engine, chapter):
        self.engine = engine
        self.goal = chapter["goal"]
        self.id = chapter["id"]
        self.player = "w" if chapter["orientation"] == "white" else "b"
        self.positions = 0
        self.memo = {}

    def reached(self, score):
        """Whether a score for the reader passes the goal at the end."""
        if self.goal["result"] == "evalIn":
            cp = white_cp(score, self.player)
            return cp >= self.goal["cp"] if self.player == "w" else cp <= self.goal["cp"]
        return is_level(score)

    def near_target(self, score):
        if score[0] == "mate":
            return False
        if self.goal["result"] == "evalIn":
            return abs(white_cp(score, self.player) - self.goal["cp"]) < NEAR
        return abs(abs(score[1]) - 150) < NEAR

    def after_reader(self, fen, move, score, played):
        """The result of a move of the reader that is no mistake: "s" solved, "x" the goal is out of reach, or the
        opponent's answer and the next position."""
        child, legal, in_check = self.engine.board(fen, [move])
        if not legal:
            return "s" if in_check or self.goal["result"] != "evalIn" else "x"
        level_goal = self.goal["result"] != "evalIn"
        if played >= self.goal["moves"]:
            # Near the target, the position after the move gets its own search, as the app judges it.
            if self.near_target(score):
                answer = self.engine.analyse(child, 1, NODES_LAST.get(self.id, NODES_ONE))
                score = (answer[0][1][0], -answer[0][1][1])
            return "s" if self.reached(score) else "x"
        if level_goal and not is_level(score):
            return "x"
        reply = self.engine.analyse(child, 1, NODES_ONE)[0][0]
        after, legal, in_check = self.engine.board(child, [reply])
        if not legal:
            return "x" if in_check or not level_goal else "s"
        node = self.reader_node(after, played)
        return {"r": reply, "n": node} if node_solvable(node) else "x"

    def reader_node(self, fen, played):
        key = (" ".join(fen.split()[:4]), played)
        if key in self.memo:
            return self.memo[key]
        self.positions += 1
        if self.positions > MAX_POSITIONS:
            raise RuntimeError("too many positions")
        _, legal, _ = self.engine.board(fen)
        lines = self.engine.analyse(fen, min(len(legal), 250), NODES_ALL)
        before = chances(lines[0][1])
        moves, other = [], []
        for index, (move, score) in enumerate(lines):
            if is_failure(before, chances(score), index == 0):
                continue
            # The last move is only judged, so all of them are; earlier ones open a tree, so only the best few.
            if played + 1 < self.goal["moves"] and len([m for m in moves if m[1] != "x"]) >= MAX_EXPLORED:
                other.append(move)
                continue
            moves.append([move, self.after_reader(fen, move, score, played + 1)])
        node = {"m": moves}
        if other:
            node["o"] = other
        self.memo[key] = node
        return node

    def tree(self, fen):
        _, legal, _ = self.engine.board(fen)
        if fen.split()[1] != self.player:
            reply = self.engine.analyse(fen, 1, NODES_ONE)[0][0]
            after, _, _ = self.engine.board(fen, [reply])
            return {"r": reply, "n": self.reader_node(after, 0)}
        return self.reader_node(fen, 0)


def node_solvable(node):
    return any(result == "s" or isinstance(result, dict) for _, result in node["m"])


def chapters(practice):
    for section in practice["sections"]:
        for study in section["studies"]:
            for chapter in study["chapters"]:
                goal = chapter.get("goal") or {}
                # The long endgames (holding a draw for 7 to 30 moves) would make trees too large to carry.
                if goal.get("result") == "evalIn" or (goal.get("result") == "equalIn" and goal.get("moves", 99) <= 2):
                    yield chapter


def work(args):
    stockfish, chapter = args
    engine = Engine(stockfish)
    judge = Chapter(engine, chapter)
    # A chapter that fails, or whose goal cannot be reached, is kept without a tree, which build.lua leaves out.
    try:
        tree = judge.tree(chapter["fen"])
        error = None if node_solvable(tree.get("n", tree)) else "not solvable"
    except Exception as problem:
        tree, error = None, "%s: %s" % (type(problem).__name__, problem)
    finally:
        engine.send("quit")
    return chapter["id"], {"tree": tree if error is None else None, "positions": judge.positions, "error": error}


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: eval_trees.py <practice.json> <stockfish> <output.json> [chapter id ...]")
    practice_path, stockfish, output = sys.argv[1:4]
    only = set(sys.argv[4:])
    with open(practice_path) as file:
        practice = json.load(file)
    todo = [c for c in chapters(practice) if not only or c["id"] in only]
    probe = Engine(stockfish)
    name = probe.name()
    probe.send("quit")
    results = {}
    with ProcessPoolExecutor() as pool:
        for chapter_id, result in pool.map(work, [(stockfish, c) for c in todo]):
            results[chapter_id] = result
            status = result["error"] or "solvable"
            print("%s: %d positions, %s" % (chapter_id, result["positions"], status), flush=True)
    # With chapters named, the others already in the output stay as they were.
    if only:
        try:
            with open(output) as file:
                kept = json.load(file)["chapters"]
            kept.update(results)
            results = kept
        except FileNotFoundError:
            pass
    out = {"engine": name, "nodes_all": NODES_ALL, "nodes_one": NODES_ONE, "nodes_last": NODES_LAST, "max_explored": MAX_EXPLORED, "chapters": results}
    with open(output, "w") as file:
        json.dump(out, file, sort_keys=True, separators=(",", ":"))
    print("written: %s (%d chapters)" % (output, len(results)))


if __name__ == "__main__":
    main()
