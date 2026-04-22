# 参数配置与统计口径说明

这份文档专门说明：

- 实验矩阵中的字段分别表示什么
- 运行脚本支持哪些常用环境变量
- `tx_results.csv`、`summary.json` 中各项统计指标是怎么计算出来的
- 这些指标分别应该如何理解

如果你只想知道“实验怎么跑”，请看：

- [README.md](/home/nitro/Desktop/experiments/README.md)

## 一、实验矩阵字段说明

四类实验矩阵文件分别是：

- `matrix_correctness.json`
- `matrix_performance.json`
- `matrix_threshold.json`
- `matrix_fault.json`

每个 case 都是一个 JSON 对象，常见字段如下。

## 1. 基础字段

- `name`
  - case 名称
  - 例如：`perf_remote_mixed_10pct_fail`

- `mode`
  - 背书模式
  - 常见取值：
    - `disabled`：关闭背书逻辑
    - `remote`：由远程背书节点完成背书

- `tx_total`
  - 该 case 总发送交易数

- `tps`
  - 发送速率
  - 用于控制 `send_workload.sh` 中两次发送启动的时间间隔

- `send_mode`
  - 发送模式
  - 当前主要使用：
    - `concurrent`
    - `sequential`

- `concurrency`
  - 并发发送上限
  - 仅在 `send_mode=concurrent` 时有意义

- `fail_ratio`
  - fail 交易比例
  - 例如：
    - `0.1` 表示 10% fail
    - `0.3` 表示 30% fail

## 2. 背书与候选块相关字段

- `default_threshold`
  - 默认策略门限
  - 通常用于 keep 交易

- `strict_threshold`
  - 严格策略门限
  - 通常用于 fail 地址或严格策略交易

- `default_aggregation`
  - 默认策略聚合方式
  - 当前通常为 `bls`

- `strict_aggregation`
  - 严格策略聚合方式
  - 当前通常为 `bls`

- `batching_window_ms`
  - Sequencer 候选块聚合窗口
  - 会传给 `node-1` 启动参数：
    - `--execution.sequencer.experimental-batching-window`

- `block_endorsement_timeout_ms`
  - 区块级背书等待超时
  - 会传给：
    - `--execution.endorsement-experiment.block-endorsement-timeout`

- `max_rebuild_rounds`
  - 最多允许候选块重建的轮数

## 3. 账户池相关字段

- `use_account_pool`
  - 是否为该 case 使用独立账户池
  - 推荐在 `performance`、`threshold`、`fault` 中保持为 `true`
  - 主要用于避免并发发送时共享账户带来的 nonce 冲突

- `pool_fund_amount`
  - 为账户池中每个账户预充值的金额
  - 默认值一般为 `0.02ether`

## 4. 故障相关字段

- `fault`
  - 故障注入描述
  - 常见取值：
    - `none`
    - `delay:node-2:100ms`
    - `delay:node-2:5000ms`
    - `down:node-2`
    - `down:node-2,node-3`

### `fault` 的含义

- `delay:node-2:100ms`
  - 在 `node-2` 上对网络接口注入 100ms 延迟

- `down:node-2`
  - 让 `node-2` 相关服务停掉，再由 `fault_injector.sh clear` 阶段恢复

## 5. 背书节点重写相关字段

这些字段主要用于阈值实验中的 partial reject 场景：

- `endorser_a_reject_to`
- `endorser_b_reject_to`
- `endorser_c_reject_to`

含义是：

- 指定某个背书节点对某个 `to` 地址的交易直接拒签

例如：

- `endorser_a_reject_to = 0x2222...`
- `endorser_b_reject_to = ""`
- `endorser_c_reject_to = ""`

表示：

- A 拒签该地址交易
- B、C 不拒签

## 6. 目标地址覆盖字段

- `to_keep_override`
- `to_fail_override`

用于在个别 case 中临时覆盖默认的：

- `TO_KEEP`
- `TO_FAIL`

## 二、脚本环境变量说明

## 1. `run_all_experiments.sh`

常用环境变量如下。

- `RESULTS_DIR`
  - 默认结果目录
  - 默认值：`$ROOT_DIR/results`

- `ACCOUNTS_DIR`
  - 账户文件目录
  - 默认值：`$ROOT_DIR/accounts_pool`

- `NODE1_BOOTSTRAP_SCRIPT`
  - `node-1` 重启脚本路径
  - 默认值：`/data/node1_redeploy.sh`

- `NODE1_RPC_URL`
  - 默认 RPC
  - 默认值：`http://127.0.0.1:8547`

- `SSH_PASSWORD`
  - 远程 SSH 密码
  - 若设置了这个值，则脚本会通过 `sshpass` 发起远程重启或故障注入

- `NODE2_SSH`
- `NODE3_SSH`
- `NODE4_SSH`
  - 三台背书节点的 SSH 地址

- `NODE2_START_CMD`
- `NODE3_START_CMD`
- `NODE4_START_CMD`
  - 三台背书节点的启动命令

### fault 组专用环境变量

- `FAULT_TX_TOTAL`
- `FAULT_TPS`
- `FAULT_SEND_MODE`
- `FAULT_CONCURRENCY`
- `FAULT_FAIL_RATIO`
- `FAULT_BATCHING_WINDOW_MS`
- `FAULT_BLOCK_ENDORSEMENT_TIMEOUT_MS`
- `FAULT_MAX_REBUILD_ROUNDS`

这些变量会覆盖 `matrix_fault.json` 中未显式设置的默认值。

## 2. `run_matrix.sh`

- `ACCOUNTS_DIR`
- `NODE1_BOOTSTRAP_CMD`

其中：

- `NODE1_BOOTSTRAP_CMD`
  - 非常重要
  - 如果为空，`run_case.sh` 不会在每个 case 前重启 `node-1`
  - 对 `threshold` 组尤其关键

## 3. `run_case.sh`

常用环境变量：

- `NODE1_RPC_URL`
- `NODE1_BOOTSTRAP_CMD`
- `FAULT_STATUS_DIR`
- `NONCE_CACHE_FILE`
- `SEQUENCER_LOG_PATH`
- `NODE2_SSH`
- `NODE3_SSH`
- `NODE4_SSH`
- `SSH_PASSWORD`
- `NODE2_START_CMD`
- `NODE3_START_CMD`
- `NODE4_START_CMD`
- `DEFAULT_ENDORSER_REJECT_TO`

## 4. `send_workload.sh`

主要参数包括：

- `--rpc`
- `--tx-total`
- `--tps`
- `--fail-ratio`
- `--out`
- `--key-keep`
- `--key-fail`
- `--addr-keep`
- `--addr-fail`
- `--to-keep`
- `--to-fail`
- `--send-mode`
- `--concurrency`
- `--keep-pool-env`
- `--fail-pool-env`

## 三、结果文件说明

## 1. `tx_results.csv`

逐笔交易结果文件，表头为：

```csv
seq,tx_type,send_ts_ns,send_done_ts_ns,completion_ts_ns,tx_hash,receipt_ts_ns,receipt_status,block_number,success_latency_ms,error,error_stage
```

字段说明如下：

- `seq`
  - 发送序号，从 1 开始

- `tx_type`
  - `keep` 或 `fail`

- `send_ts_ns`
  - 开始调用 `cast send` 的时间戳，单位纳秒

- `send_done_ts_ns`
  - `cast send` 返回的时间戳，单位纳秒

- `completion_ts_ns`
  - 该笔交易整个处理结束时刻
  - 如果交易成功收到回执，则等于或接近 `receipt_ts_ns`
  - 如果发送阶段就失败，则通常接近 `send_done_ts_ns`

- `tx_hash`
  - 交易哈希
  - 发送失败时为空

- `receipt_ts_ns`
  - 收到回执的时间戳

- `receipt_status`
  - 回执状态
  - 成功通常为 `0x1`

- `block_number`
  - 成功交易所在区块号

- `success_latency_ms`
  - 仅对成功回执交易有效
  - 表示从 `send_ts_ns` 到 `receipt_ts_ns` 的时延

- `error`
  - 错误信息
  - 例如发送失败、receipt timeout 等

- `error_stage`
  - 错误发生阶段
  - 常见为：
    - `send`
    - `receipt`

## 2. `summary.json`

这是论文分析时最常用的文件。它由 `extract_metrics.py` 从：

- `tx_results.csv`
- `sequencer.log`
- `fault_status`

汇总而来。

## 四、统计指标的计算方式与含义

下面重点说明论文中常用指标。

## 1. 成功交易数与错误交易数

- `tx_total`
  - 总交易数
  - 直接等于 `tx_results.csv` 的行数

- `tx_receipt_count`
  - 成功收到回执的交易数
  - 统计方式：
    - `receipt_status` 非空

- `tx_error_count`
  - 带错误信息的交易数
  - 统计方式：
    - `error` 非空

- `tx_send_error_count`
  - 发送阶段失败的交易数

- `tx_receipt_error_count`
  - 等待回执阶段失败的交易数

- `tx_timeout_count`
  - 超时交易数
  - 例如 `receipt_timeout`

## 2. keep / fail 语义指标

- `keep_total`
  - keep 交易总数

- `keep_success`
  - 成功进入最终区块的 keep 交易数

- `keep_retention_rate`
  - keep 保留率
  - 计算方式：

```text
keep_success / keep_total
```

- `fail_total`
  - fail 交易总数

- `fail_success`
  - 最终成功上链的 fail 交易数

- `fail_drop_rate`
  - fail 剔除率
  - 计算方式：

```text
(fail_total - fail_success) / fail_total
```

含义：

- `keep_retention_rate = 1`
  - 表示所有 keep 交易都被保留下来了

- `fail_drop_rate = 1`
  - 表示所有 fail 交易都被剔除了

## 3. 成功时延指标

- `lat_success_avg_ms`
- `lat_success_p50_ms`
- `lat_success_p95_ms`
- `lat_success_p99_ms`

这些指标只针对：

- `receipt_status` 为成功
- 即最终拿到成功回执的交易

计算基础是：

- `success_latency_ms`

其中：

```text
success_latency_ms = receipt_ts_ns - send_ts_ns
```

再换算成毫秒。

### 这些指标分别代表什么

- `lat_success_avg_ms`
  - 成功交易平均确认时延

- `lat_success_p50_ms`
  - 成功交易中位时延

- `lat_success_p95_ms`
  - 成功交易尾部时延

- `lat_success_p99_ms`
  - 更极端的尾部时延

### 为什么成功时延和 workload 不是一回事

成功时延只看：

- 最终成功那部分交易

它不包含：

- 被剔除的 fail 交易
- 发送失败的交易
- 没拿到回执的交易

所以它更适合回答：

- “成功保留下来的交易，平均要等多久？”

## 4. Workload 指标

- `workload_makespan_ms`

计算方式：

```text
max(completion_ts_ns) - min(send_ts_ns)
```

即：

- 从整批负载中第一笔交易开始发送
- 到最后一笔交易处理完成
- 整个批次跨越的总时间

### `workload_makespan_ms` 代表什么

它反映的是：

- 整批工作负载的总处理耗时

相比成功时延，它更适合回答：

- “这组实验整体跑完花了多久？”
- “同样规模的负载，在不同场景下整体处理效率如何？”

## 5. Send phase 指标

- `send_phase_makespan_ms`

计算方式：

```text
max(send_done_ts_ns) - min(send_ts_ns)
```

表示：

- 所有 `cast send` 调用开始到全部返回的总时间

它更接近“发送阶段本身”的耗时，不等于最终确认完成耗时。

## 6. 吞吐与效率指标

- `success_rate`

```text
tx_receipt_count / tx_total
```

- `success_tps`

```text
tx_receipt_count / workload_duration_s
```

- `attempt_tps`

```text
tx_total / workload_duration_s
```

- `effective_ms_per_attempt`

```text
workload_makespan_ms / tx_total
```

- `effective_ms_per_success`

```text
workload_makespan_ms / tx_receipt_count
```

### 如何理解 `effective_ms_per_success`

它不是单笔交易确认时延，而是：

- 站在整批实验负载的角度
- 平均“每获得 1 笔成功交易”所付出的总工作负载时间成本

如果 fail 比例更高、重建更多、成功交易更少，那么这个指标通常会明显变大。

## 7. 块内聚合相关指标

- `unique_success_blocks`
  - 至少包含 1 笔成功交易的区块数量

- `success_per_block_avg`
  - 平均每个成功区块里包含多少笔成功交易

计算方式：

```text
tx_receipt_count / unique_success_blocks
```

这个指标可以用来判断：

- 块内聚合是否足够强
- 成功交易是否被更均匀地压进同一个区块

## 8. 日志统计指标

这些指标来自 `sequencer.log` 的关键字统计。

- `disabled_skip`
  - 日志中 `ENDORSEMENT_DISABLED_SKIP` 的次数

- `endorsement_satisfied`
  - 日志中 `candidate block endorsement satisfied` 的次数

- `endorsement_failed`
  - 日志中 `candidate block endorsement failed` 的次数

- `rebuild_count`
  - 日志中 `rebuilding candidate block after endorsement failure` 的次数

- `remote_request_count`
  - 日志中 `REMOTE_ENDORSEMENT_REQUEST` 的次数

- `verify_ok_count`
  - 日志中 `ENDORSEMENT_COMMITMENT_CERT_VERIFY_OK` 的次数

### 这些指标如何理解

- `rebuild_count`
  - 候选块因背书失败而被重建的次数
  - 常用于分析 fail 交易、阈值不满足、故障场景下的内部代价

- `remote_request_count`
  - Sequencer 一共发起了多少次远程背书请求
  - 可以用于观察不同场景下内部请求开销

- `verify_ok_count`
  - 区块级证书校验成功次数
  - 大致对应有多少个最终成功区块完成了证书校验

## 9. 每成功交易归一化指标

- `rebuilds_per_success_tx`

```text
rebuild_count / tx_receipt_count
```

- `endorsement_failed_per_success_tx`

```text
endorsement_failed / tx_receipt_count
```

- `remote_requests_per_success_tx`

```text
remote_request_count / tx_receipt_count
```

这几个指标适合在不同成功率场景之间做归一化比较。

## 五、论文写作中如何使用这些指标

## 1. 正确性实验

重点使用：

- `tx_receipt_count`
- `keep_retention_rate`
- `fail_drop_rate`

不建议重点分析：

- 成功时延

因为正确性实验交易太少，更适合证明语义，而不是证明性能。

## 2. 基础性能实验

重点使用：

- `lat_success_avg_ms`
- `lat_success_p50_ms`
- `lat_success_p95_ms`
- `workload_makespan_ms`
- `effective_ms_per_success`
- `success_per_block_avg`
- `rebuild_count`
- `remote_request_count`

## 3. 阈值实验

正常场景重点使用：

- `lat_success_avg_ms`
- `lat_success_p95_ms`
- `remote_request_count`

部分拒签场景重点使用：

- `tx_receipt_count`
- `tx_error_count`
- `rebuild_count`

## 4. 故障实验

重点使用：

- `lat_success_avg_ms`
- `lat_success_p95_ms`
- `workload_makespan_ms`
- `keep_retention_rate`
- `rebuild_count`

其中：

- `delay` 场景适合看时延退化
- `down` / `slowhang` 场景适合看门限容错边界和超时传播代价
