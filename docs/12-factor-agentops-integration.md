# 12-Factor AgentOps: How kagent Implements Production-Ready AI Agents

> A practical guide showing how kagent embodies the 12-Factor AgentOps methodology for building reliable, observable, and portable AI agent systems on Kubernetes.

## Introduction

The **12-Factor AgentOps** methodology adapts lessons from distributed systems and cloud-native applications to the unique challenges of AI agent development. Just as the original 12-Factor App manifesto transformed how we build web services, 12-Factor AgentOps provides guardrails for building AI agents that are reliable, observable, and production-ready.

**kagent** is a Kubernetes-native AI agent framework that embodies these principles. This document shows how kagent implements each factor, with code examples demonstrating the patterns in practice.

---

## Factor I: Session Isolation

> **Principle**: Conversations are isolated units of work. Each session has its own state, history, and context that cannot leak between sessions.

### The Problem

Without session isolation, agents can mix context between users, leak sensitive information, or produce inconsistent results when handling concurrent requests.

### How kagent Implements It

kagent provides a dedicated `KAgentSessionService` that enforces session isolation at the API level:

```python
# python/packages/kagent-adk/src/kagent/adk/_session_service.py

class KAgentSessionService(BaseSessionService):
    """A session service implementation that uses the Kagent API.
    This service integrates with the Kagent server to manage session state
    and persistence through HTTP API calls.
    """

    async def create_session(
        self,
        *,
        app_name: str,
        user_id: str,
        state: Optional[dict[str, Any]] = None,
        session_id: Optional[str] = None,
    ) -> Session:
        request_data = {
            "user_id": user_id,
            "agent_ref": app_name,
        }
        if session_id:
            request_data["id"] = session_id

        response = await self.client.post(
            "/api/sessions",
            json=request_data,
            headers={"X-User-ID": user_id},
        )
        # Each session gets its own isolated state
        return Session(
            id=session_data["id"],
            user_id=session_data["user_id"],
            state=state or {},
            app_name=app_name
        )
```

**Key patterns**:
- Sessions are scoped by `user_id` and `session_id`
- State is never shared between sessions
- Each API call includes user identification headers
- Events are appended to specific sessions, maintaining history isolation

```python
async def append_event(self, session: Session, event: Event) -> Event:
    """Events are always scoped to a specific session."""
    response = await self.client.post(
        f"/api/sessions/{session.id}/events?user_id={session.user_id}",
        json=event_data,
        headers={"X-User-ID": session.user_id},
    )
```

---

## Factor II: Explicit Context

> **Principle**: All context must be explicitly declared. No hidden state, implicit assumptions, or undocumented dependencies.

### The Problem

Agents with implicit context are unpredictable. They may work in development but fail mysteriously in production because of undocumented environmental dependencies.

### How kagent Implements It

kagent uses Kubernetes Custom Resource Definitions (CRDs) to explicitly declare every aspect of an agent's configuration:

```go
// go/api/v1alpha2/agent_types.go

type DeclarativeAgentSpec struct {
    // SystemMessage explicitly declares the agent's instructions
    SystemMessage string `json:"systemMessage,omitempty"`

    // SystemMessageFrom allows external configuration
    SystemMessageFrom *ValueSource `json:"systemMessageFrom,omitempty"`

    // ModelConfig explicitly references the LLM configuration
    ModelConfig string `json:"modelConfig,omitempty"`

    // Tools explicitly lists available capabilities
    Tools []*Tool `json:"tools,omitempty"`

    // A2AConfig explicitly declares agent-to-agent communication
    A2AConfig *A2AConfig `json:"a2aConfig,omitempty"`
}
```

Model configuration is also fully explicit:

```go
// go/api/v1alpha2/modelconfig_types.go

type ModelConfigSpec struct {
    Model string `json:"model"`

    // API key is explicitly referenced via Secret
    APIKeySecret string `json:"apiKeySecret"`
    APIKeySecretKey string `json:"apiKeySecretKey"`

    // Provider is explicitly declared
    Provider ModelProvider `json:"provider"`

    // TLS configuration is explicit
    TLS *TLSConfig `json:"tls,omitempty"`
}
```

**Example Agent Definition**:

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: k8s-assistant
spec:
  type: Declarative
  description: "Kubernetes troubleshooting agent"
  declarative:
    systemMessage: |
      You are a Kubernetes expert assistant.
      Help users diagnose and resolve cluster issues.
    modelConfig: default-model-config
    tools:
      - type: McpServer
        mcpServer:
          name: kubectl-tool
          toolNames:
            - get_pods
            - describe_resource
```

Every dependency, every configuration, every capability is declared upfront. No surprises.

---

## Factor III: Focused Agents

> **Principle**: Each agent should do one thing well. Compose multiple focused agents rather than building monolithic super-agents.

### The Problem

Monolithic agents that try to do everything become unpredictable, hard to test, and impossible to reason about.

### How kagent Implements It

kagent supports agent composition through the `Tool.Agent` reference type, allowing agents to delegate to specialized sub-agents:

```go
// go/api/v1alpha2/agent_types.go

type Tool struct {
    Type ToolProviderType `json:"type,omitempty"`

    // McpServer references external tool providers
    McpServer *McpServerTool `json:"mcpServer,omitempty"`

    // Agent references another agent as a tool
    Agent *TypedLocalReference `json:"agent,omitempty"`
}
```

The translator handles nested agent composition:

```go
// go/internal/controller/translator/agent/adk_api_translator.go

case tool.Agent != nil:
    toolAgent := &v1alpha2.Agent{}
    err := a.kube.Get(ctx, agentRef, toolAgent)

    // Nested agents become remote agent tools
    url := fmt.Sprintf("http://%s.%s:8080", toolAgent.Name, toolAgent.Namespace)
    cfg.RemoteAgents = append(cfg.RemoteAgents, adk.RemoteAgentConfig{
        Name:        utils.ConvertToPythonIdentifier(utils.GetObjectRef(toolAgent)),
        Url:         url,
        Description: toolAgent.Spec.Description,
    })
```

**Example Multi-Agent Composition**:

```yaml
# Root orchestrator agent
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: sre-assistant
spec:
  declarative:
    systemMessage: "Coordinate between specialized agents"
    tools:
      - type: Agent
        agent:
          name: k8s-agent      # Focused on Kubernetes
      - type: Agent
        agent:
          name: prometheus-agent  # Focused on metrics
      - type: Agent
        agent:
          name: logs-agent     # Focused on logging
```

The framework also enforces a DAG (Directed Acyclic Graph) to prevent circular dependencies:

```go
func (a *adkApiTranslator) validateAgent(ctx context.Context, agent *v1alpha2.Agent, state *tState) error {
    if state.isVisited(agentRef) {
        return fmt.Errorf("cycle detected in agent tool chain: %s -> %s", agentRef, agentRef)
    }
    if state.depth > MAX_DEPTH {
        return fmt.Errorf("recursion limit reached in agent tool chain")
    }
}
```

---

## Factor IV: Observable State

> **Principle**: Agent behavior must be observable. Log decisions, trace tool calls, meter resource usage.

### How kagent Implements It

kagent integrates OpenTelemetry throughout the stack, providing distributed tracing, structured logging, and metrics:

```python
# python/packages/kagent-core/src/kagent/core/tracing/_span_processor.py

class KagentAttributesSpanProcessor(SpanProcessor):
    """A SpanProcessor that adds kagent-specific attributes to all spans."""

    def on_start(self, span: Span, parent_context: Optional[otel_context.Context] = None) -> None:
        ctx = parent_context if parent_context is not None else otel_context.get_current()
        attributes = ctx.get(KAGENT_ATTRIBUTES_KEY)

        if attributes and isinstance(attributes, dict):
            for key, value in attributes.items():
                if value is not None:
                    span.set_attribute(key, value)
```

The agent executor automatically adds tracing attributes:

```python
# python/packages/kagent-adk/src/kagent/adk/_agent_executor.py

# Prepare span attributes
span_attributes = {}
if run_args.get("user_id"):
    span_attributes["kagent.user_id"] = run_args["user_id"]
if context.task_id:
    span_attributes["gen_ai.task.id"] = context.task_id
if run_args.get("session_id"):
    span_attributes["gen_ai.conversation.id"] = run_args["session_id"]

# Set kagent span attributes for all spans in context
context_token = set_kagent_span_attributes(span_attributes)
```

**Helm Configuration for Observability**:

```yaml
# helm/kagent/values.yaml

otel:
  tracing:
    enabled: false
    exporter:
      otlp:
        endpoint: http://host.docker.internal:4317
        insecure: true
  logging:
    enabled: false
    exporter:
      otlp:
        endpoint: http://host.docker.internal:4317

metrics:
  enabled: true
  serviceMonitor:
    enabled: false
    path: /metrics
```

---

## Factor V: Stateless Workers

> **Principle**: Agent workers should be stateless. Store state externally so workers can be scaled, replaced, or restarted without data loss.

### How kagent Implements It

kagent agents are deployed as Kubernetes Deployments with all state stored externally:

```go
// go/internal/controller/translator/agent/adk_api_translator.go

deployment := &appsv1.Deployment{
    Spec: appsv1.DeploymentSpec{
        Replicas: dep.Replicas,
        Strategy: appsv1.DeploymentStrategy{
            Type: appsv1.RollingUpdateDeploymentStrategyType,
            RollingUpdate: &appsv1.RollingUpdateDeployment{
                MaxUnavailable: &intstr.IntOrString{Type: intstr.Int, IntVal: 0},
                MaxSurge:       &intstr.IntOrString{Type: intstr.Int, IntVal: 1},
            },
        },
        Template: corev1.PodTemplateSpec{
            Spec: corev1.PodSpec{
                // Stateless container - configuration mounted from Secrets
                Containers: []corev1.Container{{
                    Name:  "kagent",
                    Image: dep.Image,
                    // Health checks ensure readiness
                    ReadinessProbe: &corev1.Probe{
                        ProbeHandler: corev1.ProbeHandler{
                            HTTPGet: &corev1.HTTPGetAction{
                                Path: "/health",
                                Port: intstr.FromString("http"),
                            },
                        },
                    },
                }},
            },
        },
    },
}
```

For LangGraph agents, kagent provides a remote checkpointer that stores state externally:

```python
# python/packages/kagent-langgraph/src/kagent/langgraph/_checkpointer.py

class KAgentCheckpointer(BaseCheckpointSaver[str]):
    """A remote checkpointer that stores LangGraph state in KAgent via the Go service.

    This checkpointer calls the KAgent Go HTTP service to persist graph state,
    enabling distributed execution and session recovery.
    """

    async def aput(
        self,
        config: RunnableConfig,
        checkpoint: Checkpoint,
        metadata: CheckpointMetadata,
        new_versions: ChannelVersions,
    ) -> RunnableConfig:
        """Store a checkpoint via the KAgent Go service."""
        thread_id, user_id, checkpoint_ns = self._extract_config_values(config)

        # State is serialized and stored externally
        type_, serialized_checkpoint = self.serde.dumps_typed(checkpoint)

        response = await self.client.post(
            "/api/langgraph/checkpoints",
            json=request_data.model_dump(),
            headers={"X-User-ID": user_id},
        )
```

**Scaling Configuration**:

```yaml
# helm/kagent/values.yaml

controller:
  replicas: 1

ui:
  replicas: 1

pdb:
  enabled: false
  controller:
    minAvailable: 1
  ui:
    minAvailable: 1
```

---

## Factor VI: Resume Work

> **Principle**: Agents should be able to resume interrupted work. Persist state at meaningful checkpoints.

### How kagent Implements It

The session service maintains complete event history, enabling conversations to resume:

```python
# python/packages/kagent-adk/src/kagent/adk/_session_service.py

async def get_session(
    self,
    *,
    app_name: str,
    user_id: str,
    session_id: str,
    config: Optional[GetSessionConfig] = None,
) -> Optional[Session]:
    url = f"/api/sessions/{session_id}?user_id={user_id}"
    if config:
        if config.num_recent_events:
            url += f"&limit={config.num_recent_events}"
        else:
            url += "&limit=-1"  # Return all events

    response = await self.client.get(url, headers={"X-User-ID": user_id})

    # Reconstruct session with full event history
    events: list[Event] = []
    for event_data in events_data:
        events.append(Event.model_validate_json(event_data["data"]))

    session = Session(
        id=session_data["id"],
        user_id=session_data["user_id"],
        events=events,
        app_name=app_name,
    )

    # Replay events to restore state
    for event in events:
        await super().append_event(session, event)

    return session
```

The LangGraph checkpointer enables resumption at any checkpoint:

```python
async def aget_tuple(self, config: RunnableConfig) -> CheckpointTuple | None:
    """Retrieve the latest checkpoint for a thread."""
    thread_id, user_id, checkpoint_ns = self._extract_config_values(config)

    response = await self.client.get(
        "/api/langgraph/checkpoints",
        params={"thread_id": thread_id, "checkpoint_ns": checkpoint_ns, "limit": "1"},
    )

    # Return checkpoint with full state for resumption
    return CheckpointTuple(
        config=config,
        checkpoint=self.serde.loads_typed(...),
        metadata=...,
        parent_config=...,
        pending_writes=...,
    )
```

---

## Factor VII: Smart Routing

> **Principle**: Route requests intelligently based on complexity, user tier, or agent specialization.

### How kagent Implements It

kagent implements smart routing through the A2A (Agent-to-Agent) protocol:

```go
// go/internal/a2a/manager.go

type PassthroughManager struct {
    client *client.A2AClient
}

func (m *PassthroughManager) OnSendMessage(ctx context.Context, request protocol.SendMessageParams) (*protocol.MessageResult, error) {
    if request.Message.MessageID == "" {
        request.Message.MessageID = protocol.GenerateMessageID()
    }
    return m.client.SendMessage(ctx, request)
}

func (m *PassthroughManager) OnSendMessageStream(ctx context.Context, request protocol.SendMessageParams) (<-chan protocol.StreamingMessageEvent, error) {
    return m.client.StreamMessage(ctx, request)
}
```

The controller watches for agent changes and routes requests appropriately:

```go
// go/internal/controller/agent_controller.go

func (r *AgentController) SetupWithManager(mgr ctrl.Manager) error {
    build := ctrl.NewControllerManagedBy(mgr).
        For(&v1alpha2.Agent{}).
        Watches(
            &v1alpha2.ModelConfig{},
            handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
                // Route reconciliation to affected agents
                return r.findAgentsUsingModelConfig(ctx, mgr.GetClient(), ...)
            }),
        ).
        Watches(
            &v1alpha2.RemoteMCPServer{},
            handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
                return r.findAgentsUsingRemoteMCPServer(ctx, mgr.GetClient(), ...)
            }),
        )
}
```

**Multi-Agent Routing Example**:

```yaml
# Route based on agent specialization
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: router-agent
spec:
  declarative:
    systemMessage: |
      Route user requests to the appropriate specialist agent:
      - Infrastructure issues -> k8s-agent
      - Performance questions -> prometheus-agent
      - Security concerns -> security-agent
    tools:
      - type: Agent
        agent:
          name: k8s-agent
      - type: Agent
        agent:
          name: prometheus-agent
      - type: Agent
        agent:
          name: security-agent
```

---

## Factor VIII: Human Validation

> **Principle**: Critical actions require human approval. Build review workflows into the agent lifecycle.

### How kagent Implements It

kagent provides comprehensive Human-in-the-Loop (HITL) support through the A2A protocol:

```python
# python/packages/kagent-core/src/kagent/core/a2a/_hitl.py

@dataclass
class ToolApprovalRequest:
    """Generic structure for a tool call requiring approval."""
    name: str
    args: dict[str, Any]
    id: str | None = None


async def handle_tool_approval_interrupt(
    action_requests: list[ToolApprovalRequest],
    task_id: str,
    context_id: str,
    event_queue: EventQueue,
    task_store: TaskStore,
) -> None:
    """Send input_required event for tool approval."""

    # Build human-readable message
    text_parts = format_tool_approval_text_parts(action_requests)

    # Build structured DataPart for programmatic processing
    interrupt_data = {
        "interrupt_type": KAGENT_HITL_INTERRUPT_TYPE_TOOL_APPROVAL,
        "action_requests": [
            {"name": req.name, "args": req.args, "id": req.id}
            for req in action_requests
        ],
    }

    # Send input_required event - agent pauses for human decision
    await event_queue.enqueue_event(
        TaskStatusUpdateEvent(
            task_id=task_id,
            status=TaskStatus(
                state=TaskState.input_required,
                timestamp=datetime.now(UTC).isoformat(),
                message=Message(parts=message_parts),
            ),
            final=False,  # Not final - waiting for user input
        )
    )
```

Decision extraction supports both structured and natural language responses:

```python
def extract_decision_from_message(message: Message | None) -> DecisionType | None:
    """Extract decision from A2A message using two-tier detection.

    Priority:
    1. Structured DataPart with decision_type field (most reliable)
    2. Keyword matching in TextPart (fallback for human input)
    """
    # Priority 1: Look for structured DataPart
    for part in message.parts:
        if isinstance(inner, DataPart):
            decision = extract_decision_from_data_part(inner.data)
            if decision:
                return decision

    # Priority 2: Fallback to keyword matching ("approve", "deny", etc.)
    for part in message.parts:
        if isinstance(inner, TextPart):
            decision = extract_decision_from_text(inner.text)
            if decision:
                return decision

    return None
```

---

## Factor IX: Bounded Execution

> **Principle**: Agent execution should have explicit bounds. Set timeouts, token limits, and iteration caps.

### How kagent Implements It

kagent enforces execution bounds at multiple levels:

**Token and Resource Limits in ModelConfig**:

```go
// go/api/v1alpha2/modelconfig_types.go

type OpenAIConfig struct {
    // Maximum tokens to generate
    MaxTokens int `json:"maxTokens,omitempty"`

    // Timeout for requests
    Timeout *int `json:"timeout,omitempty"`
}

type AnthropicConfig struct {
    // Maximum tokens to generate
    MaxTokens int `json:"maxTokens,omitempty"`
}
```

**Kubernetes Resource Limits**:

```go
// go/internal/controller/translator/agent/adk_api_translator.go

func getDefaultResources(spec *corev1.ResourceRequirements) corev1.ResourceRequirements {
    if spec == nil {
        return corev1.ResourceRequirements{
            Requests: corev1.ResourceList{
                corev1.ResourceCPU:    resource.MustParse("100m"),
                corev1.ResourceMemory: resource.MustParse("384Mi"),
            },
            Limits: corev1.ResourceList{
                corev1.ResourceCPU:    resource.MustParse("2000m"),
                corev1.ResourceMemory: resource.MustParse("1Gi"),
            },
        }
    }
    return *spec
}
```

**Streaming Timeouts**:

```yaml
# helm/kagent/values.yaml

controller:
  streaming:
    maxBufSize: 1Mi
    initialBufSize: 4Ki
    timeout: 600s  # 10 minute maximum
```

**Agent Recursion Limits**:

```go
const MAX_DEPTH = 10

func (a *adkApiTranslator) validateAgent(ctx context.Context, agent *v1alpha2.Agent, state *tState) error {
    if state.depth > MAX_DEPTH {
        return fmt.Errorf("recursion limit reached in agent tool chain")
    }
}
```

---

## Factor X: Graceful Degradation

> **Principle**: When things go wrong, fail gracefully. Provide fallbacks, retry strategies, and clear error messages.

### How kagent Implements It

The agent executor catches and handles errors gracefully, providing meaningful feedback:

```python
# python/packages/kagent-adk/src/kagent/adk/_agent_executor.py

async def execute(self, context: RequestContext, event_queue: EventQueue):
    try:
        await self._handle_request(context, event_queue, runner, run_args)
    except Exception as e:
        logger.error("Error handling A2A request: %s", e, exc_info=True)

        # Detect common failure patterns and provide helpful messages
        error_message = str(e)
        if "JSONDecodeError" in error_message or "Unterminated string" in error_message:
            if "function_call" in error_message.lower():
                error_message = (
                    "The model does not support function calling properly. "
                    "This error typically occurs when using Ollama models with tools. "
                    "Please either:\n"
                    "1. Remove tools from the agent configuration, or\n"
                    "2. Use a model that supports function calling."
                )

        # Publish structured failure event
        await event_queue.enqueue_event(
            TaskStatusUpdateEvent(
                task_id=context.task_id,
                status=TaskStatus(
                    state=TaskState.failed,
                    message=Message(parts=[Part(TextPart(text=error_message))]),
                ),
                final=True,
            )
        )
```

**Rolling Updates for Zero-Downtime Deployments**:

```go
Strategy: appsv1.DeploymentStrategy{
    Type: appsv1.RollingUpdateDeploymentStrategyType,
    RollingUpdate: &appsv1.RollingUpdateDeployment{
        MaxUnavailable: &intstr.IntOrString{Type: intstr.Int, IntVal: 0},
        MaxSurge:       &intstr.IntOrString{Type: intstr.Int, IntVal: 1},
    },
},
```

---

## Factor XI: Fail-Safe Checks

> **Principle**: Build safety checks into critical paths. Validate inputs, sanitize outputs, and verify tool calls.

### How kagent Implements It

kagent implements multiple layers of safety checks:

**Input Validation via Kubernetes CEL Rules**:

```go
// go/api/v1alpha2/agent_types.go

// +kubebuilder:validation:XValidation:message="type must be specified",rule="has(self.type)"
// +kubebuilder:validation:XValidation:message="declarative must be specified if type is Declarative",rule="(self.type == 'Declarative' && has(self.declarative)) || (self.type == 'BYO' && has(self.byo))"
type AgentSpec struct {
    Type AgentType `json:"type"`
    ...
}
```

**Sandboxed Code Execution**:

```python
# python/packages/kagent-adk/src/kagent/adk/sandbox_code_executer.py

class SandboxedLocalCodeExecutor(BaseCodeExecutor):
    """A code executor that executes code in a sandbox."""

    # Cannot be stateful - enforces isolation
    stateful: bool = Field(default=False, frozen=True, exclude=True)

    def execute_code(self, invocation_context, code_execution_input) -> CodeExecutionResult:
        try:
            # Execute inside sandbox runtime (srt)
            proc = subprocess.run(
                ["srt", "python", "-"],
                input=code_execution_input.code,
                capture_output=True,
                text=True,
            )
            return CodeExecutionResult(
                stdout=proc.stdout or "",
                stderr=proc.stderr or "",
                output_files=[],
            )
        except FileNotFoundError as e:
            return CodeExecutionResult(stdout="", stderr=f"Execution failed: {e}")
```

**Agent Cycle Detection**:

```go
func (a *adkApiTranslator) validateAgent(ctx context.Context, agent *v1alpha2.Agent, state *tState) error {
    agentRef := utils.GetObjectRef(agent)

    if state.isVisited(agentRef) {
        return fmt.Errorf("cycle detected in agent tool chain: %s -> %s", agentRef, agentRef)
    }

    if agentRef.Namespace == agent.Namespace && agentRef.Name == agent.Name {
        return fmt.Errorf("agent tool cannot be used to reference itself, %s", agentRef)
    }
}
```

---

## Factor XII: Portable Agents

> **Principle**: Agents should be portable across environments. Use standard protocols and avoid vendor lock-in.

### How kagent Implements It

kagent embraces open standards and Kubernetes-native patterns:

**Multi-Provider Model Support**:

```go
// go/api/v1alpha2/modelconfig_types.go

type ModelProvider string

const (
    ModelProviderAnthropic         ModelProvider = "Anthropic"
    ModelProviderAzureOpenAI       ModelProvider = "AzureOpenAI"
    ModelProviderOpenAI            ModelProvider = "OpenAI"
    ModelProviderOllama            ModelProvider = "Ollama"
    ModelProviderGemini            ModelProvider = "Gemini"
    ModelProviderGeminiVertexAI    ModelProvider = "GeminiVertexAI"
    ModelProviderAnthropicVertexAI ModelProvider = "AnthropicVertexAI"
)
```

**Standard MCP Protocol for Tools**:

```go
// Remote MCP servers use standard HTTP/SSE protocols
type RemoteMCPServerSpec struct {
    URL      string                   `json:"url"`
    Protocol RemoteMCPServerProtocol  `json:"protocol,omitempty"`
    Headers  []ValueRef               `json:"headersFrom,omitempty"`
}

const (
    RemoteMCPServerProtocolSse           = "sse"
    RemoteMCPServerProtocolStreamableHttp = "streamable-http"
)
```

**A2A Protocol for Agent Communication**:

The A2A (Agent-to-Agent) protocol provides a standardized way for agents to communicate, regardless of their underlying implementation.

**Kubernetes-Native Deployment**:

```yaml
# Agents are portable across any Kubernetes cluster
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: portable-agent
spec:
  type: Declarative
  declarative:
    modelConfig: default-model-config
    systemMessage: "A portable agent"
---
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: default-model-config
spec:
  provider: OpenAI  # Easily switch to Anthropic, Gemini, etc.
  model: gpt-4
  apiKeySecret: openai-key
  apiKeySecretKey: OPENAI_API_KEY
```

---

## Summary: kagent and 12-Factor AgentOps

| Factor | Principle | kagent Implementation |
|--------|-----------|----------------------|
| **I. Session Isolation** | Isolated conversation state | `KAgentSessionService` with user/session scoping |
| **II. Explicit Context** | No hidden dependencies | CRDs for Agent, ModelConfig, RemoteMCPServer |
| **III. Focused Agents** | Single responsibility | Agent composition via `Tool.Agent` references |
| **IV. Observable State** | Full observability | OpenTelemetry integration, Prometheus metrics |
| **V. Stateless Workers** | External state storage | K8s Deployments + remote session/checkpoint storage |
| **VI. Resume Work** | Checkpoint and resume | Session event history, LangGraph checkpointer |
| **VII. Smart Routing** | Intelligent request routing | A2A protocol, controller watches |
| **VIII. Human Validation** | Approval workflows | HITL support with `input_required` state |
| **IX. Bounded Execution** | Resource limits | Token limits, timeouts, K8s resource quotas |
| **X. Graceful Degradation** | Meaningful failures | Error handling with helpful messages, rolling updates |
| **XI. Fail-Safe Checks** | Input validation | CEL validation, sandboxed execution, cycle detection |
| **XII. Portable Agents** | Provider agnostic | Multi-provider support, standard protocols (MCP, A2A) |

---

## Getting Started

Ready to build 12-Factor compliant agents with kagent?

1. **Install kagent**: Follow the [installation guide](https://kagent.dev/docs/getting-started)
2. **Configure a provider**: Set up your LLM provider via ModelConfig
3. **Create your first agent**: Define an Agent CRD with explicit tools and system message
4. **Add observability**: Enable OpenTelemetry tracing
5. **Implement HITL**: Add approval workflows for critical actions

---

## Resources

- [kagent Documentation](https://kagent.dev/docs)
- [12-Factor AgentOps Methodology](https://github.com/boshu/12-factor-agentops)
- [MCP Protocol](https://modelcontextprotocol.io)
- [A2A Protocol](https://github.com/google/A2A)
