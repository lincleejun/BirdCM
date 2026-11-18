from birdcm.evaluate import score


def res(top1s, subject=0, rejected=False):
    boxes = [{"species": {"top5": [{"sci": t}] + [{"sci": "z"}] * 4}} for t in top1s]
    sp = boxes[subject]["species"] if boxes and not rejected else None
    return {"boxes": boxes, "rejected": rejected or not boxes, "species": sp}


def test_fixed_denominators():
    rows = [{"kind": "bird", "truth": "a", "result": res(["a"]), "error": None},          # right
            {"kind": "bird", "truth": "a", "result": res(["b", "a"]), "error": None},     # wrong box chosen
            {"kind": "bird", "truth": "a", "result": res(["a"], rejected=True), "error": None},  # lost to the gate
            {"kind": "bird", "truth": "a", "result": res([]), "error": None},             # no box
            {"kind": "bird", "truth": "a", "result": None, "error": "boom"},              # failed
            {"kind": "mammal", "truth": "m", "result": res(["x"]), "error": None}]
    r = score(rows)
    assert r["bird_photos"] == 5 and r["bird_found"] == 3 and r["kept"] == 2 and r["rejected_by_gate"] == 1
    assert r["top1"] == 1 and r["top1_pct"] == 20.0 and r["oracle_top1"] == 3 and r["subject_choice_pct"] == 33.33
    assert r["failed"] == 1 and r["mammal_rejected"] == 0
