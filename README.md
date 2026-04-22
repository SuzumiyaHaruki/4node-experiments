# 裸机实验脚本说明

这个目录用于在 4 台裸机或云主机上复现实验，不依赖 Docker Compose。当前默认拓扑为：

- `node-1`：Sequencer / RPC / 实验驱动节点
- `node-2`：背书节点 A
- `node-3`：背书节点 B
- `node-4`：背书节点 C

实验覆盖四类场景：

- `correctness`：正确性实验
- `performance`：基础性能实验
- `threshold`：阈值配置实验
- `fault`：故障注入实验

实验运行过程中生成的主要产物包括：

- `accounts_pool/`：为各 case 预生成的账户文件和账户池
- `results/`：各类实验输出目录
- `results/<group>/<case>/tx_results.csv`
- `results/<group>/<case>/summary.json`
- `results/<group>/<case>/summary.tsv`
- `results/<group>/<case>/sequencer.log`

如果你想查看参数和指标定义，请同时参考：

- [PARAMETERS_AND_METRICS.md](/home/nitro/Desktop/experiments/PARAMETERS_AND_METRICS.md)

## 仓库结构

- `README.md`：实验运行说明
- `PARAMETERS_AND_METRICS.md`：参数配置与统计口径说明
- `matrix_correctness.json`：正确性实验矩阵
- `matrix_performance.json`：基础性能实验矩阵
- `matrix_threshold.json`：阈值实验矩阵
- `matrix_fault.json`：故障实验矩阵
- `prepare_accounts.sh`：生成单个 case 的基础账户文件
- `prepare_accounts_pool.sh`：为整张矩阵生成基础账户文件
- `prepare_keep_pool.sh`：为 keep 交易生成账户池
- `prepare_fail_pool.sh`：为 fail 交易生成账户池
- `send_workload.sh`：发送交易并记录逐笔结果
- `run_case.sh`：执行单个 case
- `run_matrix.sh`：执行整张矩阵
- `run_all_experiments.sh`：按顺序执行四类实验
- `fault_injector.sh`：通过 SSH 对背书节点注入故障
- `extract_metrics.py`：从 `tx_results.csv` 和日志中提取汇总指标
- `generate_thesis_figures.py`：从 `results/` 生成论文图表

## 前置条件

### 1. 四台机器的软件准备

所有实验机建议具备以下命令：

- `bash`
- `curl`
- `jq`
- `python3`
- `ssh`
- `scp`

`node-1` 还需要：

- `cast`

如果需要使用密码登录的故障注入和远程重启能力，还需要：

- `sshpass`

### 2. 节点部署准备

在跑实验前，默认你已经完成以下部署：

- `node-2`、`node-3`、`node-4` 已经部署好 `nitro-val + endorser`
- 对应机器上已有：
  - `/data/node2_start.sh`
  - `/data/node3_start.sh`
  - `/data/node4_start.sh`
- `node-1` 上已有：
  - `/data/node1_redeploy.sh`
- `node-1` 的 RPC 可通过 `http://127.0.0.1:8547` 访问

### 3. 连通性检查

推荐在 `node-1` 上先检查：

```bash
cast chain-id --rpc-url http://127.0.0.1:8547
cast block-number --rpc-url http://127.0.0.1:8547

curl -fsS http://192.168.1.13:9001/healthz && echo
curl -fsS http://192.168.1.6:9002/healthz && echo
curl -fsS http://192.168.1.4:9003/healthz && echo
```

如果以上命令都能正常返回，再开始跑实验。

## 结果目录约定

推荐统一把结果放在仓库内的 `results/` 下：

- `results/correctness`
- `results/performance`
- `results/threshold`
- `results/fault`

每个 case 目录通常包含：

- `tx_results.csv`：逐笔交易结果
- `summary.json`：该 case 的汇总指标
- `summary.tsv`：便于快速查看的表格形式
- `sequencer.log`：仅截取该 case 运行期间的 sequencer 日志

## 最常用的运行方式

## 1. 更新仓库

如果仓库已经存在：

```bash
cd /data/4node-experiments
git pull --ff-only
```

如果是第一次拉取：

```bash
git clone git@github.com:SuzumiyaHaruki/4node-experiments.git /data/4node-experiments
cd /data/4node-experiments
```

## 2. 一键跑完整实验

这是最推荐的用法，适合正式跑一轮完整实验。

```bash
cd /data/4node-experiments
export SSH_PASSWORD='你的密码'
./run_all_experiments.sh
```

说明：

- `correctness`、`performance`、`threshold` 会按 case 重新 bootstrap `node-1`
- `fault` 会先统一把 `node-1` 切到故障实验所需运行态，再依次执行故障矩阵
- 每类实验开始前，脚本都会尝试把三台背书节点恢复到默认配置

## 3. 只跑某一类实验

### 只跑 correctness

```bash
cd /data/4node-experiments
rm -rf ./results/correctness
mkdir -p ./results/correctness
NODE1_BOOTSTRAP_CMD='RESET_CHAIN=1 bash /data/node1_redeploy.sh' \
  ./run_matrix.sh ./matrix_correctness.json ./results/correctness
```

### 只跑 performance

```bash
cd /data/4node-experiments
rm -rf ./results/performance
mkdir -p ./results/performance
NODE1_BOOTSTRAP_CMD='RESET_CHAIN=1 bash /data/node1_redeploy.sh' \
  ./run_matrix.sh ./matrix_performance.json ./results/performance
```

### 只跑 threshold

```bash
cd /data/4node-experiments
rm -rf ./results/threshold
mkdir -p ./results/threshold
export SSH_PASSWORD='你的密码'
NODE1_BOOTSTRAP_CMD='RESET_CHAIN=1 bash /data/node1_redeploy.sh' \
  ./run_matrix.sh ./matrix_threshold.json ./results/threshold
```

注意：

- `threshold` 这一组必须带 `NODE1_BOOTSTRAP_CMD`
- 否则 `node-1` 可能沿用旧运行态，导致阈值实验实际没有切换到目标门限

### 只跑 fault

```bash
cd /data/4node-experiments
rm -rf ./results/fault
mkdir -p ./results/fault
export SSH_PASSWORD='你的密码'
./run_matrix.sh ./matrix_fault.json ./results/fault
```

如果你希望 fault 之前先手工把 `node-1` 切到指定配置，可以先执行：

```bash
DEFAULT_THRESHOLD=2 STRICT_THRESHOLD=3 bash /data/node1_redeploy.sh
```

## 4. 只跑单个 case

格式如下：

```bash
./run_case.sh <matrix.json> <case_name> <case_env> <out_dir>
```

例如：

```bash
cd /data/4node-experiments
NODE1_BOOTSTRAP_CMD='RESET_CHAIN=1 bash /data/node1_redeploy.sh' \
  ./run_case.sh \
  ./matrix_threshold.json \
  threshold_partial_reject_3of3 \
  ./accounts_pool/threshold_partial_reject_3of3.env \
  ./results/threshold
```

## 账户准备方式

一般情况下，不需要手工单独准备账户，因为：

- `run_matrix.sh` 会先调用 `prepare_accounts_pool.sh`
- `run_case.sh` 在 `use_account_pool=true` 时，还会继续生成 keep / fail 账户池

但如果你想提前准备某组账户，也可以手工执行：

```bash
cd /data/4node-experiments
FUND_AMOUNT=5ether ./prepare_accounts_pool.sh ./matrix_performance.json ./accounts_pool
```

说明：

- `prepare_accounts_pool.sh` 会按矩阵里每个 case 生成 `accounts_pool/<case>.env`
- `run_case.sh` 会在此基础上继续为 keep/fail 交易生成独立账户池
- 这样做的目的，是避免并发发送时因为共享 nonce 导致 `nonce too high`

## 结果查看

## 1. 查看某个 case 的摘要

```bash
jq . ./results/performance/perf_remote_mixed_10pct_fail/summary.json
```

## 2. 快速查看同一组实验

```bash
cd /data/4node-experiments
for d in results/threshold/*; do
  [ -d "$d" ] || continue
  echo "== $(basename "$d") =="
  jq '{case_name,tx_total,tx_receipt_count,tx_error_count,lat_success_avg_ms,lat_success_p95_ms,workload_makespan_ms,rebuild_count,remote_request_count}' "$d/summary.json"
done
```

## 3. 生成论文图

如果已经有 `results/`，可以直接生成论文图片：

```bash
cd /home/nitro/Desktop/experiments
python3 generate_thesis_figures.py --results-dir /home/nitro/Desktop/results --out-dir /home/nitro/Desktop/figures
```

## 常用环境变量

以下变量最常用：

- `NODE1_BOOTSTRAP_SCRIPT`
  - 默认值：`/data/node1_redeploy.sh`
- `NODE1_BOOTSTRAP_CMD`
  - 控制每个 case 是否在开始前重启 `node-1`
- `NODE1_RPC_URL`
  - 默认值：`http://127.0.0.1:8547`
- `SSH_PASSWORD`
  - 密码登录三台背书节点时使用
- `NODE2_SSH`
- `NODE3_SSH`
- `NODE4_SSH`
- `NODE2_START_CMD`
- `NODE3_START_CMD`
- `NODE4_START_CMD`
- `RESULTS_DIR`
- `ACCOUNTS_DIR`
- `FUND_AMOUNT`
- `NONCE_CACHE_FILE`

故障实验还常用：

- `FAULT_TX_TOTAL`
- `FAULT_TPS`
- `FAULT_SEND_MODE`
- `FAULT_CONCURRENCY`
- `FAULT_FAIL_RATIO`
- `FAULT_BATCHING_WINDOW_MS`
- `FAULT_BLOCK_ENDORSEMENT_TIMEOUT_MS`
- `FAULT_MAX_REBUILD_ROUNDS`

这些变量的具体含义，请看：

- [PARAMETERS_AND_METRICS.md](/home/nitro/Desktop/experiments/PARAMETERS_AND_METRICS.md)

## 推荐实验顺序

建议按下面顺序跑：

1. `correctness`
2. `performance`
3. `threshold`
4. `fault`

原因是：

- 先确认语义是否正确
- 再看正常运行下的性能
- 再看阈值差异
- 最后做故障退化分析

## 常见问题

## 1. 为什么 threshold 跑出来还是 2-of-3

常见原因是：

- 直接执行了 `./run_matrix.sh ./matrix_threshold.json ...`
- 但没有设置 `NODE1_BOOTSTRAP_CMD`

这样 `node-1` 会沿用旧运行态，而不会按每个 case 的阈值重启。

## 2. 为什么 performance / fault 会出现 nonce 问题

旧版本实验脚本中，多个并发交易可能共享同一账户并竞争 nonce。现在默认通过 keep / fail 账户池避免这个问题。如果仍出现异常，请优先检查：

- 是否使用了最新版仓库
- `use_account_pool` 是否为 `true`
- 是否手工覆盖了发送相关参数

## 3. 为什么 slowhang 会比普通 one-down 慢很多

因为 `one-down degraded` 更接近“节点快速失效”，而 `slowhang` 是“节点一直拖到接近超时”。两者都会减少有效背书节点，但对端到端时延的影响完全不同。

## 4. 我该看哪个文件判断实验是否成功

最推荐先看：

- `summary.json`

如果摘要不符合预期，再看：

- `tx_results.csv`
- `sequencer.log`

## 5. 指标口径去哪里看

统一看：

- [PARAMETERS_AND_METRICS.md](/home/nitro/Desktop/experiments/PARAMETERS_AND_METRICS.md)
