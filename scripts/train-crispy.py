#!/usr/bin/env python3
"""
train-crispy.py - Train a Crispy-style kill detector (the "student").

Consumes the auto-labelled crops harvested by detect-fortnite.py
(dataset/<game>/{kill,nokill}/*.png) and trains a small fully-connected
network with the exact topology Crispy uses:

    [N*N, 120, 15, 2]  with Sigmoid activations, no bias

The weights are saved both as a Crispy-compatible .npy (list of [out,in]
matrices) and as an ONNX graph (MatMul + Sigmoid chain) ready for fast
inference. This lets OCR-labelled data become a model that runs in
milliseconds instead of seconds.

Pure numpy (no torch) to keep the dependency surface tiny.
"""

import argparse
import glob
import os
import sys

import numpy as np


def load_dataset(root, size):
    """Load grayscale crops into X (n, size*size) in [0,1] and y (n,) {0,1}."""
    from PIL import Image
    X, y = [], []
    for label, sub in ((1, "kill"), (0, "nokill")):
        for path in sorted(glob.glob(os.path.join(root, sub, "*.png"))):
            img = Image.open(path).convert("L").resize((size, size))
            X.append(np.asarray(img, dtype=np.float32).reshape(-1) / 255.0)
            y.append(label)
    if not X:
        sys.exit(f"No training data found under {root}/{{kill,nokill}}")
    return np.asarray(X, dtype=np.float32), np.asarray(y, dtype=np.int64)


def sigmoid(z):
    return 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))


def train(X, y, layers, epochs, lr, batch, seed=0):
    """Train an MLP with sigmoid activations and no bias. Returns weight list."""
    rng = np.random.default_rng(seed)
    # Xavier-ish init; weights stored as [in, out] during training.
    W = []
    dims = [X.shape[1]] + layers
    for i in range(len(dims) - 1):
        scale = np.sqrt(2.0 / (dims[i] + dims[i + 1]))
        W.append(rng.standard_normal((dims[i], dims[i + 1])).astype(np.float32) * scale)

    # One-hot targets for the 2-unit output [no-kill, kill].
    T = np.zeros((len(y), 2), dtype=np.float32)
    T[np.arange(len(y)), y] = 1.0

    n = len(X)
    for epoch in range(epochs):
        idx = rng.permutation(n)
        total_loss = 0.0
        for s in range(0, n, batch):
            b = idx[s:s + batch]
            xb, tb = X[b], T[b]
            # Forward
            acts = [xb]
            for w in W:
                acts.append(sigmoid(acts[-1] @ w))
            out = acts[-1]
            total_loss += float(np.mean((out - tb) ** 2)) * len(b)
            # Backward (MSE + sigmoid derivative)
            delta = (out - tb) * out * (1 - out)
            grads = [None] * len(W)
            for li in range(len(W) - 1, -1, -1):
                grads[li] = acts[li].T @ delta / len(b)
                if li > 0:
                    a = acts[li]
                    delta = (delta @ W[li].T) * a * (1 - a)
            for li in range(len(W)):
                W[li] -= lr * grads[li]
        if (epoch + 1) % max(1, epochs // 10) == 0 or epoch == 0:
            acc = evaluate(X, y, W)
            print(f"  epoch {epoch + 1:3d}/{epochs}  loss={total_loss / n:.4f}  acc={acc:.3f}")
    return W


def evaluate(X, y, W):
    a = X
    for w in W:
        a = sigmoid(a @ w)
    pred = a.argmax(axis=1)
    return float((pred == y).mean())


def export_onnx(W, input_size, path):
    """Export the trained net as a Crispy-format ONNX (MatMul + Sigmoid)."""
    import onnx
    from onnx import helper, TensorProto

    nodes, inits = [], []
    layer_input = "input"
    for i, w in enumerate(W):  # w is [in, out] already (ONNX MatMul layout)
        out_name = f"layer{i}_output" if i < len(W) - 1 else "output"
        wname = f"fc{i}_weight"
        inits.append(helper.make_tensor(
            wname, TensorProto.FLOAT, list(w.shape), w.flatten().tolist()))
        nodes.append(helper.make_node(
            "MatMul", [layer_input, wname], [f"{out_name}_mm"], name=f"matmul_{i}"))
        nodes.append(helper.make_node(
            "Sigmoid", [f"{out_name}_mm"], [out_name], name=f"sigmoid_{i}"))
        layer_input = out_name

    g = helper.make_graph(
        nodes, "crispy_kill_detector",
        [helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, input_size])],
        [helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 2])],
        inits)
    m = helper.make_model(g, producer_name="train-crispy")
    m.opset_import[0].version = 13
    onnx.checker.check_model(m)
    onnx.save(m, path)


def main():
    ap = argparse.ArgumentParser(description="Train a Crispy-style kill detector")
    ap.add_argument("--game", default="fortnite")
    ap.add_argument("--dataset", default=None,
                    help="Dataset root (default dataset/<game>)")
    ap.add_argument("--size", type=int, default=100,
                    help="Square input size (NxN); 100 -> 10000 inputs")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--lr", type=float, default=0.5)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--hidden", default="120,15",
                    help="Hidden layer sizes (Crispy uses 120,15)")
    ap.add_argument("--out-onnx", default=None)
    ap.add_argument("--out-npy", default=None)
    args = ap.parse_args()

    dataset = args.dataset or os.path.join("dataset", args.game)
    out_onnx = args.out_onnx or os.path.join("models", f"crispy_{args.game}.onnx")
    out_npy = args.out_npy or os.path.join("models", f"{args.game}.npy")

    X, y = load_dataset(dataset, args.size)
    layers = [int(h) for h in args.hidden.split(",")] + [2]
    print(f"[train] {len(X)} samples ({int(y.sum())} kill / {int((1 - y).sum())} nokill), "
          f"input={X.shape[1]}, layers={layers}")

    W = train(X, y, layers, args.epochs, args.lr, args.batch)
    print(f"[train] final accuracy: {evaluate(X, y, W):.3f}")

    os.makedirs(os.path.dirname(out_onnx) or ".", exist_ok=True)
    export_onnx(W, X.shape[1], out_onnx)
    # Crispy .npy format stores [out, in] matrices -> transpose back.
    np.save(out_npy, np.array([w.T for w in W], dtype=object), allow_pickle=True)
    print(f"[train] saved {out_onnx} and {out_npy}")


if __name__ == "__main__":
    main()
