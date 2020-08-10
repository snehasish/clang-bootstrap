# clang-bootstrap
Scripts to bootstrap clang and measure performance.

## Usage
1. Git clone github.com/llvm-project
2. Install dependencies - cmake ninja clang lld linux-perf-5.2
3. Set env var `LLVM_PROJECT` to point to location in (1). 
4. Build the compilers `make pgo-vanilla-compiler pgo-split-compiler`
5. Benchmark the compilers `make benchmark-pgo-vanilla benchmark-pgo-split` 

## Compiler Flavours
1. plain-compiler: Release mode compiler, no assertions
2. pgo-vanilla: plain compiler + Instr. PGO 
3. afdo-vanilla: plain compiler + Sample PGO
4. pgo-split: pgo-vanilla + machine-function-splitter enabled
5. pgo-hcs: pgo-vanilla + hot-cold-split pass enabled
