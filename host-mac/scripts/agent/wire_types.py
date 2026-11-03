"""Static wire types matching Agent/Schemas JSON contracts."""

from typing import Literal, NotRequired, TypeAlias, TypedDict


class IDTarget(TypedDict):
    id: int


class PointTarget(TypedDict):
    x: float
    y: float


Target: TypeAlias = IDTarget | PointTarget


class ClickAction(TypedDict):
    type: Literal["click"]
    target: Target
    button: NotRequired[Literal["left", "middle", "right"]]
    count: NotRequired[int]


class TypeAction(TypedDict):
    type: Literal["type"]
    text: str
    mode: Literal["replace", "append"]
    target: NotRequired[Target]


class KeyAction(TypedDict):
    type: Literal["key"]
    chord: str


class ScrollAction(TypedDict):
    type: Literal["scroll"]
    direction: Literal["up", "down", "left", "right"]
    amount: float
    target: NotRequired[Target]


class SelectAction(TypedDict):
    type: Literal["select"]
    target: Target
    option: str


DragAction = TypedDict(
    "DragAction",
    {"type": Literal["drag"], "from": Target, "to": Target},
)


class OpenURLAction(TypedDict):
    type: Literal["open_url"]
    url: str


class OpenAppAction(TypedDict):
    type: Literal["open_app"]
    name: str


class FindFilesAction(TypedDict):
    type: Literal["find_files"]
    query: str
    kind: NotRequired[str]
    modified_after: NotRequired[str]


class SetFilesAction(TypedDict):
    type: Literal["set_files"]
    target: Target
    file_ids: list[str]


class WaitAction(TypedDict):
    type: Literal["wait"]
    seconds: float


class AskUserAction(TypedDict):
    type: Literal["ask_user"]
    question: str
    choices: NotRequired[list[str]]


class DoneAction(TypedDict):
    type: Literal["done"]
    answer: str


class FailAction(TypedDict):
    type: Literal["fail"]
    reason: str


Action: TypeAlias = (
    ClickAction
    | TypeAction
    | KeyAction
    | ScrollAction
    | SelectAction
    | DragAction
    | OpenURLAction
    | OpenAppAction
    | FindFilesAction
    | SetFilesAction
    | WaitAction
    | AskUserAction
    | DoneAction
    | FailAction
)


class WebSurface(TypedDict):
    kind: Literal["web"]
    url: str
    title: NotRequired[str]


class AppSurface(TypedDict):
    kind: Literal["app"]
    app: str
    title: NotRequired[str]


Surface: TypeAlias = WebSurface | AppSurface


# JSON arrays are represented as lists; the schema fixes each array's length.
BoundingBox: TypeAlias = list[float]


class Element(TypedDict):
    id: int
    role: str
    name: str
    value: str | None
    state: list[str]
    bbox: BoundingBox
    in_view: bool


class Focus(TypedDict):
    id: int
    role: str
    name: str
    value_prefix: str
    selection: list[int]


class HistoryItem(TypedDict):
    action: Action | None
    result: str


class Budget(TypedDict):
    step: int
    max_steps: int


class Observation(TypedDict):
    task: str
    surface: Surface
    screenshot: str
    elements: list[Element]
    focus: Focus | None
    history: list[HistoryItem]
    budget: Budget


class Gate(TypedDict):
    decision: Literal["allowed", "needs_approval", "rejected"]
    reason: str
    fingerprint: NotRequired[str]
    scope_identity: NotRequired[str]
    risk_tier: NotRequired[Literal["low", "medium", "high"]]


class Execution(TypedDict):
    status: Literal["ok", "rejected", "error", "not_executed"]
    result: str


class Timings(TypedDict):
    observation_ms: int
    policy_ms: int
    gate_ms: int
    execution_ms: int
    record_ms: int
    total_ms: int


class EpisodeStep(TypedDict):
    type: Literal["step"]
    episode_id: str
    step: int
    observation: Observation
    prompt_version: str
    source: NotRequired[Literal["direct"]]
    raw_model_output: str
    action: Action | None
    gate: Gate
    execution: Execution
    timings: Timings


class EpisodeFooter(TypedDict):
    type: Literal["footer"]
    episode_id: str
    outcome: str
    approvals: list[str]
    corrections: list[str]
    checker_verdict: NotRequired[str]


Episode: TypeAlias = EpisodeStep | EpisodeFooter
