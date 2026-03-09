# Swift HF API

A Swift client for Hugging Face's REST APIs

This package aims to offer improvements on Swift Hugging Face, including better performance and ergonomics. Refer to the [benchmarks](#benchmarks) to compare the performance of Swift HF API and Swift Hugging Face.

Swift HF API is independently maintained and is not associated with Hugging Face.

## Benchmarks

The benchmarks use tests from MLX Swift LM and can be run from this package in Xcode.

Set `HFAPI_ENABLE_BENCHMARKS=1` to include the benchmark target in the package graph, then set `RUN_BENCHMARKS=1` in the test scheme environment to run the benchmark suite.

These results were observed on an M3 MacBook Pro.

| Benchmark | Swift HF API median | Swift Hugging Face median | Swift HF API Performance |
| --- | ---: | ---: | --- |
| Download cache hit | 0.6 ms | 144.0 ms | 240.00x faster |
| LLM load | 77.9 ms | 317.0 ms | 4.07x faster |
| VLM load | 198.9 ms | 408.2 ms | 2.05x faster |
| Embedding load | 90.5 ms | 262.8 ms | 2.90x faster |
