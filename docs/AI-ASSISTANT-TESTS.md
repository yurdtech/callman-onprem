# AI assistant tests

An AI assistant test is a scenario of its own type. It sends questions to your company's assistant, grades the answers, and can check what the assistant really did (a database row, a Kafka event) with the ordinary steps.

## The `ai-worker`

These runs can take hours, so they have their own queue and worker. They never share a process with other scenario runs.

- **Docker Compose:** the `ai-worker` service starts with the stack. `docker compose up -d --scale ai-worker=N` adds more.
- **Helm:** `aiWorker.enabled` (default `true`), `aiWorker.replicaCount` (default 1), `aiWorker.concurrency`.

It is the backend image with `WORKER_QUEUES=ai-scenarios`. Keep at least one running: with none, starting a run answers 503 and a scheduled run is skipped. Do not scale it to zero.

If a pod stops mid-run, another continues after the last finished question. The question in flight is asked again, so a test that changes data should reset it in its first step.

## Network

The `ai-worker` must reach the assistant under test and the AI models that judge answers. If you use a NetworkPolicy or an egress proxy, open both.

## AI models

AI models are added in the admin panel under **AI Settings → Connected AI providers**: OpenAI, Anthropic, Google Gemini, DeepSeek, or an OpenAI-compatible server (Ollama, vLLM, LiteLLM, a company gateway). To keep answers inside your network, use your own server: Gemini, DeepSeek, OpenAI and Anthropic send what they judge to that provider. Personal data is masked before a judge reads an answer.

## Settings

| Variable | Default | |
|---|---|---|
| `AI_WORKER_CONCURRENCY` | 4 | Test runs one worker runs at once |
| `AI_SCENARIO_RUN_MAX_DURATION_MS` | 14400000 | Longest run (4 hours) |
| `AI_SCENARIO_NODE_MAX_DURATION_MS` | 300000 | Longest step |
| `AI_SCENARIO_REQUEST_TIMEOUT_MS` | 120000 | Longest request step |
| `AI_SCENARIO_DATASET_MAX_ROWS` | 5000 | Most questions in one run |
| `AI_RUN_RETENTION_DAYS` | 90 | Days stored answers are kept. 0 keeps them forever |
