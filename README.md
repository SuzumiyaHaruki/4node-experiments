# 裸机实验脚本

这是一个独立的实验仓库，用来在 4 台裸机/云主机上复现实验。

它的定位是：

- 基于 `node-1` + `node-2/3/4` 的四机拓扑
- 不依赖 Docker Compose
- 可直接用于 correctness / performance / threshold / fault 四类实验
- 产物会落在本目录下的 `results/`、`accounts_pool/` 等目录中，便于归档和重复实验

这套脚本的思路参考了 `endorsement/nitro-testnode/experiments`，但改成了更适合当前裸机部署的版本。

## 仓库结构

- `README.md`：仓库说明和使用方式
- `prepare_accounts.sh`：准备单个 case 的账户
- `prepare_accounts_pool.sh`：批量准备矩阵账户
- `send_workload.sh`：向 `node-1` 发交易
- `run_case.sh`：执行单个实验 case
- `run_matrix.sh`：按矩阵批量执行 case
- `run_all_experiments.sh`：按顺序执行四类实验
- `fault_injector.sh`：通过 SSH 对背书节点注入故障
- `extract_metrics.py`：汇总交易结果和日志指标
- `matrix_*.json`：四类实验矩阵

## 输出目录约定

建议把实验输出放在仓库内的独立目录中，例如：

- `results/correctness`
- `results/performance`
- `results/threshold`
- `results/fault`

脚本默认不会覆盖仓库里的脚本文件，只会在你指定的输出目录里生成：

- `tx_results.csv`
- `summary.json`
- `summary.tsv`

## 目录内容

- `prepare_accounts.sh`
- `prepare_accounts_pool.sh`
- `send_workload.sh`
- `run_case.sh`
- `run_matrix.sh`
- `fault_injector.sh`
- `extract_metrics.py`
- `matrix_correctness.json`
- `matrix_fault.json`
- `matrix_threshold.json`
- `matrix_performance.json`

## 总体流程

1. 先确认 4 台机器已经通过 `scripts/` 里的启动脚本部署完成。
2. 在 `node-1` 上确保 `http://127.0.0.1:8547` 可用。
3. 用 `prepare_accounts_pool.sh` 为某个矩阵批量准备账户。
4. 用 `run_case.sh` 跑单个 case，或者用 `run_matrix.sh` 跑整张矩阵。
5. 需要故障注入时，用 `fault_injector.sh` 手动对某台背书节点加延迟或停机。

## 推荐使用方式

如果你想把“拉取仓库”和“准备账户”留在命令行里，把“正式执行实验”收进脚本，推荐按下面的顺序来：

### 1. 拉取实验仓库

```bash
cd /data/4node-experiments
git pull --ff-only
```

如果你第一次拉取：

```bash
git clone git@github.com:SuzumiyaHaruki/4node-experiments.git /data/4node-experiments
cd /data/4node-experiments
```

### 2. 准备账户

先为所有矩阵生成账户池：

```bash
cd /data/4node-experiments
FUND_AMOUNT=5ether ./prepare_accounts_pool.sh ./matrix_correctness.json ./accounts_pool
FUND_AMOUNT=5ether ./prepare_accounts_pool.sh ./matrix_performance.json ./accounts_pool
FUND_AMOUNT=5ether ./prepare_accounts_pool.sh ./matrix_threshold.json ./accounts_pool
FUND_AMOUNT=5ether ./prepare_accounts_pool.sh ./matrix_fault.json ./accounts_pool
```

说明：

- `prepare_accounts_pool.sh` 会在开始时自动清空 nonce 缓存，避免前一轮实验重启 `node-1` 后留下旧 nonce。
- 如果你确实想保留缓存，可以设置 `KEEP_NONCE_CACHE=1`。

### 3. 执行实验

直接运行总脚本：

```bash
cd /data/4node-experiments
./run_all_experiments.sh
```

如果你的 `node1_redeploy.sh` 不在默认路径 `/data/node1_redeploy.sh`，可以这样指定：

```bash
NODE1_BOOTSTRAP_SCRIPT=/home/nitro/Desktop/endorsement/scripts/node1_redeploy.sh ./run_all_experiments.sh
```

如果你的 `node-2/3/4` SSH 地址和默认值不同，也可以在执行前覆盖：

```bash
NODE2_SSH=root@192.168.1.13 NODE3_SSH=root@192.168.1.6 NODE4_SSH=root@192.168.1.4 ./run_all_experiments.sh
```

## 前置条件

### 所有实验机

- `cast`
- `jq`
- `python3`
- `curl`
- `ssh`
- `scp`

### `node-1`

- `cast` 可以连到 `http://127.0.0.1:8547`
- 3 台背书节点已经可达

### 3 台背书节点

- `node-2`、`node-3`、`node-4` 的 `endorser` 已启动
- 如果要用 `fault_injector.sh` 的 `down`/`clear`，建议把 `node2_start.sh`、`node3_start.sh`、`node4_start.sh`
  也拷到对应机器的 `/data/` 下

## 快速开始

### 1. 批量准备账户

```bash
cd /home/nitro/Desktop/experiments
./prepare_accounts_pool.sh ./matrix_correctness.json ./accounts_pool
```

### 2. 跑一个 case

```bash
./run_case.sh ./matrix_correctness.json correct_1keep_1fail ./accounts_pool/correct_1keep_1fail.env ./exp_correctness/correct_1keep_1fail
```

### 3. 跑整张矩阵

```bash
./run_matrix.sh ./matrix_correctness.json ./exp_correctness
```

### 4. 一键执行全部实验

```bash
./run_all_experiments.sh
```

## 运行时覆盖

### `prepare_accounts.sh`

- `L2_RPC_URL`
- `FUNDER_KEY`
- `FUND_AMOUNT`
- `NONCE_CACHE_FILE`

### `run_case.sh`

- `NODE1_BOOTSTRAP_CMD`
  - 如果设置了这个变量，脚本会在每个 case 开始前执行它
  - 适合做阈值实验时切换 `node-1` 启动参数
- `NODE1_RPC_URL`
- `NODE2_SSH`
- `NODE3_SSH`
- `NODE4_SSH`

### `fault_injector.sh`

- `NODE2_SSH`
- `NODE3_SSH`
- `NODE4_SSH`
- `NODE2_START_CMD`
- `NODE3_START_CMD`
- `NODE4_START_CMD`

## 推荐实验顺序

1. `matrix_correctness.json`
2. `matrix_performance.json`
3. `matrix_threshold.json`
4. `matrix_fault.json`

## 各类实验怎么跑

下面默认你已经：

1. 用 `scripts/` 里的脚本把 4 台机器部署好了
2. `node-1` 的 RPC 已经可用，默认是 `http://127.0.0.1:8547`
3. `node-2/3/4` 的 `nitro-val + endorser` 都在运行
4. 在 `./experiments` 目录下执行命令

### 1. Correctness

目标是验证在不同 keep/fail 组合下，交易是否都能按预期完成。

推荐先跑整张矩阵：

```bash
cd /home/nitro/Desktop/experiments
./run_matrix.sh ./matrix_correctness.json ./results/correctness
```

这会依次跑下面这些 case：

- `correct_single_keep`
- `correct_single_fail`
- `correct_1keep_1fail`
- `correct_2keep_1fail`
- `correct_2fail_1keep`

如果你只想先看单个 case，可以直接跑：

```bash
./run_case.sh ./matrix_correctness.json correct_1keep_1fail ./accounts_pool/correct_1keep_1fail.env ./results/correctness
```

这类实验通常不需要改 `node-1` 启动参数。

### 2. Performance

目标是观察不同流量和失败比例下的延迟、吞吐和成功率。

推荐直接跑整张矩阵：

```bash
cd /home/nitro/Desktop/experiments
./run_matrix.sh ./matrix_performance.json ./results/performance
```

常见 case 包括：

- `perf_baseline_keep_only`
- `perf_local_keep_only`
- `perf_remote_keep_only`
- `perf_remote_mixed_10pct_fail`
- `perf_remote_mixed_30pct_fail`

这些 case 默认的 `tx_total` 都是 100，`tps` 都是 5。  
如果你想自己做一个更小的 smoke test，可以单独跑一个 case 再把 `tx_total` 改小一点，先确认链路没问题。

### 3. Threshold

目标是比较不同背书阈值下的行为，例如 `2of3` 和 `3of3`。

这类实验的关键点是：**每个 case 之前需要把 `node-1` 用对应阈值重新拉起**。  
本目录里已经预留了 `NODE1_BOOTSTRAP_CMD`，所以你可以在 `run_case.sh` 前先重启 `node-1`。

推荐做法是直接配合 `NODE1_BOOTSTRAP_CMD` 跑单个 case：

```bash
cd /home/nitro/Desktop/experiments
NODE1_BOOTSTRAP_CMD='DEFAULT_THRESHOLD=2 STRICT_THRESHOLD=3 bash /home/nitro/Desktop/endorsement/scripts/node1_redeploy.sh' \
  ./run_case.sh ./matrix_threshold.json threshold_2of3_fail20 ./accounts_pool/threshold_2of3_fail20.env ./results/threshold
```

如果你想切成 `3of3`，就改成：

```bash
NODE1_BOOTSTRAP_CMD='DEFAULT_THRESHOLD=3 STRICT_THRESHOLD=3 bash /home/nitro/Desktop/endorsement/scripts/node1_redeploy.sh' \
  ./run_case.sh ./matrix_threshold.json threshold_3of3_fail20 ./accounts_pool/threshold_3of3_fail20.env ./results/threshold
```

矩阵里常见 case 有：

- `threshold_2of3_fail20`
- `threshold_3of3_fail20`
- `threshold_2of3_fail40`
- `threshold_3of3_fail40`

建议每跑一个 case 前先确认 `node-1` 已经起来，并且三个 `endorser` 的 `/healthz` 都正常。

### 4. Fault

目标是验证延迟和宕机故障下的系统表现。

推荐直接跑整张矩阵：

```bash
cd /home/nitro/Desktop/experiments
./run_matrix.sh ./matrix_fault.json ./results/fault
```

常见 case 包括：

- `fault_remote_normal`
- `fault_delay_100ms`
- `fault_delay_300ms`
- `fault_delay_500ms`
- `fault_down_1`
- `fault_down_2`

其中：

- `delay:node-2:100ms` 表示给 `node-2` 加 100ms 延迟
- `down:node-2` 表示停掉 `node-2`
- `down:node-2,node-3` 表示同时停掉两台

故障实验的前提是：

1. `fault_injector.sh` 能通过 SSH 连到三台背书节点
2. 三台机器上都配置了对应的重启脚本，例如：
   - `bash /data/node2_start.sh`
   - `bash /data/node3_start.sh`
   - `bash /data/node4_start.sh`

如果你想单独验证某个故障，也可以直接跑单个 case：

```bash
./run_case.sh ./matrix_fault.json fault_delay_100ms ./accounts_pool/fault_delay_100ms.env ./results/fault
```

### 统一产物

每个 case 最终都会生成三类结果文件：

- `tx_results.csv`
- `summary.json`
- `summary.tsv`

你可以先看 `summary.tsv`，如果要做进一步分析，再看 `tx_results.csv`。

## 说明

- 这套脚本是裸机版，不再依赖 Docker Compose。
- `run_matrix.sh` 默认只负责跑 workload，不会替你自动切换 `node-1` 的阈值配置。
- 如果你要做阈值实验，建议给 `run_case.sh` 传 `NODE1_BOOTSTRAP_CMD`，在每个 case 之前重启一次 `node-1`。
