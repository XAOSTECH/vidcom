#!/usr/bin/env python3
"""
Convert Crispy .npy weights to ONNX format for C inference.

Crispy uses simple fully-connected neural networks for kill detection:
- Architecture: [input_size, 120, 15, 2] 
- Activation: Sigmoid
- Output: Binary classification (kill/no-kill)

Network resolutions by game:
- Valorant: [4000, 120, 15, 2]  (50x80 grayscale image)
- CSGO2:    [10000, 120, 15, 2] (100x100 grayscale image)
- Overwatch:[10000, 120, 15, 2] (100x100 grayscale image)
"""

import numpy as np
import onnx
from onnx import helper, TensorProto
import sys
import os

def create_fc_layer(weights, input_name, output_name, layer_idx):
    """Create a fully connected layer with sigmoid activation."""
    # Crispy weights are stored as [output_size, input_size]
    # ONNX expects [input_size, output_size] for MatMul
    weights_transposed = weights.T.astype(np.float32)
    
    # Create weight tensor
    weight_name = f"fc{layer_idx}_weight"
    weight_tensor = helper.make_tensor(
        name=weight_name,
        data_type=TensorProto.FLOAT,
        dims=weights_transposed.shape,
        vals=weights_transposed.flatten().tolist()
    )
    
    # MatMul node
    matmul_output = f"{output_name}_matmul"
    matmul_node = helper.make_node(
        'MatMul',
        inputs=[input_name, weight_name],
        outputs=[matmul_output],
        name=f"matmul_{layer_idx}"
    )
    
    # Sigmoid activation node
    sigmoid_node = helper.make_node(
        'Sigmoid',
        inputs=[matmul_output],
        outputs=[output_name],
        name=f"sigmoid_{layer_idx}"
    )
    
    return [matmul_node, sigmoid_node], [weight_tensor]

def convert_crispy_to_onnx(npy_path, output_path, input_size):
    """Convert Crispy .npy weights to ONNX model."""
    # Load weights
    weights = np.load(npy_path, allow_pickle=True)
    
    print(f"Converting {npy_path} to ONNX...")
    print(f"Number of layers: {len(weights)}")
    for i, w in enumerate(weights):
        print(f"  Layer {i}: {w.shape}")
    
    # Create nodes and initializers
    nodes = []
    initializers = []
    
    # Input
    input_tensor = helper.make_tensor_value_info(
        'input',
        TensorProto.FLOAT,
        [1, input_size]  # Batch size 1, flattened grayscale image
    )
    
    # Build layers
    layer_input = 'input'
    for i, weight_matrix in enumerate(weights):
        layer_output = f'layer{i}_output' if i < len(weights) - 1 else 'output'
        layer_nodes, layer_inits = create_fc_layer(
            weight_matrix,
            layer_input,
            layer_output,
            i
        )
        nodes.extend(layer_nodes)
        initializers.extend(layer_inits)
        layer_input = layer_output
    
    # Output (2 classes: no-kill, kill)
    output_tensor = helper.make_tensor_value_info(
        'output',
        TensorProto.FLOAT,
        [1, 2]
    )
    
    # Create graph
    graph_def = helper.make_graph(
        nodes,
        'crispy_kill_detector',
        [input_tensor],
        [output_tensor],
        initializers
    )
    
    # Create model
    model_def = helper.make_model(graph_def, producer_name='crispy_converter')
    model_def.opset_import[0].version = 13
    
    # Check and save
    onnx.checker.check_model(model_def)
    onnx.save(model_def, output_path)
    print(f"✓ Saved ONNX model to {output_path}")
    
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: convert-crispy-to-onnx.py <game>")
        print("  game: valorant, csgo2, or overwatch")
        sys.exit(1)
    
    game = sys.argv[1].lower()
    
    # Network resolutions from Crispy source
    resolutions = {
        'valorant': 4000,   # 50x80 grayscale
        'csgo2': 10000,     # 100x100 grayscale
        'overwatch': 10000  # 100x100 grayscale
    }
    
    if game not in resolutions:
        print(f"Error: Unknown game '{game}'. Must be: valorant, csgo2, or overwatch")
        sys.exit(1)
    
    models_dir = '/workspaces/vidcom/models'
    npy_path = os.path.join(models_dir, f'{game}.npy')
    onnx_path = os.path.join(models_dir, f'crispy_{game}.onnx')
    
    if not os.path.exists(npy_path):
        print(f"Error: {npy_path} not found")
        sys.exit(1)
    
    convert_crispy_to_onnx(npy_path, onnx_path, resolutions[game])
    print(f"\nConversion complete! Use this model for {game.upper()} kill detection.")
