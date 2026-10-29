/**
 * Well-known provider presets: picking one fills name, base URL and protocol,
 * so adding a provider only asks for the key.
 *
 * Endpoint data adapted from yetone/magpie's internal/provider/presets.go
 * (MIT), flattened onto Janus's single-endpoint provider model: each preset
 * maps the vendor's OpenAI Chat / OpenAI Responses / Anthropic Messages
 * endpoints to the matching Janus protocol. Every variant of a vendor —
 * global vs China site, subscription plan vs pay-as-you-go, cloud region —
 * is a `region`, so the picker holds one entry per vendor and the dialog's
 * region select is the single place variants are chosen.
 */

export type JanusProtocol =
  | "openai_chat"
  | "anthropic_messages"
  | "openai_responses"
  | "openai_decisions"

export const PROTOCOLS: JanusProtocol[] = [
  "openai_chat",
  "anthropic_messages",
  "openai_responses",
  "openai_decisions",
]

export interface PresetRegion {
  id: string
  name: string
  endpoints: Partial<Record<JanusProtocol, string>>
  /** Where API keys are made, when it differs from the preset's own page. */
  keysUrl?: string
}

export interface ProviderPreset {
  id: string
  name: string
  kind: "vendor" | "relay" | "local"
  endpoints: Partial<Record<JanusProtocol, string>>
  /** Preselected protocol — the vendor's primary API. */
  defaultProtocol: JanusProtocol
  regions?: PresetRegion[]
  /** Names what regions choose between ("Plan", "Region"); default "Region". */
  regionLabel?: string
  /** One line under the picker, e.g. which plan an endpoint serves. */
  note?: string
  /** Where API keys are made — surfaced as a "Get a key" link. */
  keysUrl?: string
  /** No key needed (local servers, free tiers): the key step is skipped. */
  noKey?: boolean
  /** For vendors reached at the user's own resource (Azure): example URL. */
  endpointPlaceholder?: string
  endpointHint?: string
}

/** The endpoints in effect for a preset at a region (or its default). */
export function presetEndpoints(preset: ProviderPreset, regionId?: string) {
  const region = preset.regions?.find((r) => r.id === regionId) ?? preset.regions?.[0]
  return region?.endpoints ?? preset.endpoints
}

export function presetKeysUrl(preset: ProviderPreset, regionId?: string) {
  const region = preset.regions?.find((r) => r.id === regionId) ?? preset.regions?.[0]
  return region?.keysUrl ?? preset.keysUrl
}

const bedrockRegions: PresetRegion[] = [
  "us-east-1",
  "us-east-2",
  "us-west-2",
  "eu-central-1",
  "eu-west-1",
  "eu-west-3",
  "ap-northeast-1",
  "ap-southeast-1",
  "ap-southeast-2",
  "ap-south-1",
].map((id) => ({
  id,
  name: id,
  endpoints: {
    openai_chat: `https://bedrock-runtime.${id}.amazonaws.com/openai/v1`,
    openai_responses: `https://bedrock-runtime.${id}.amazonaws.com/openai/v1`,
    anthropic_messages: `https://bedrock-runtime.${id}.amazonaws.com/anthropic`,
  },
}))

export const PROVIDER_PRESETS: ProviderPreset[] = [
  // ---- vendors (the model's own maker) ----
  {
    id: "anthropic",
    name: "Anthropic",
    kind: "vendor",
    endpoints: { anthropic_messages: "https://api.anthropic.com/v1" },
    defaultProtocol: "anthropic_messages",
    keysUrl: "https://console.anthropic.com/settings/keys",
  },
  {
    id: "openai",
    name: "OpenAI",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.openai.com/v1",
      openai_responses: "https://api.openai.com/v1",
      openai_decisions: "https://api.openai.com/v1",
    },
    defaultProtocol: "openai_chat",
    keysUrl: "https://platform.openai.com/api-keys",
  },
  {
    id: "google",
    name: "Google Gemini",
    kind: "vendor",
    endpoints: { openai_chat: "https://generativelanguage.googleapis.com/v1beta/openai" },
    defaultProtocol: "openai_chat",
    note: "Gemini Developer API",
    keysUrl: "https://aistudio.google.com/apikey",
  },
  {
    id: "deepseek",
    name: "DeepSeek",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.deepseek.com/v1",
      openai_responses: "https://api.deepseek.com/v1",
      anthropic_messages: "https://api.deepseek.com/anthropic",
    },
    defaultProtocol: "openai_chat",
    keysUrl: "https://platform.deepseek.com/api_keys",
  },
  {
    id: "xai",
    name: "xAI",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.x.ai/v1",
      openai_responses: "https://api.x.ai/v1",
      anthropic_messages: "https://api.x.ai",
    },
    defaultProtocol: "openai_chat",
    keysUrl: "https://console.x.ai",
  },
  {
    id: "moonshot",
    name: "Kimi",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.moonshot.ai/v1",
      anthropic_messages: "https://api.moonshot.ai/anthropic",
    },
    defaultProtocol: "openai_chat",
    regions: [
      {
        id: "global",
        name: "Global · api.moonshot.ai",
        endpoints: {
          openai_chat: "https://api.moonshot.ai/v1",
          anthropic_messages: "https://api.moonshot.ai/anthropic",
        },
        keysUrl: "https://platform.moonshot.ai/console/api-keys",
      },
      {
        id: "cn",
        name: "China · api.moonshot.cn",
        endpoints: {
          openai_chat: "https://api.moonshot.cn/v1",
          anthropic_messages: "https://api.moonshot.cn/anthropic",
        },
        keysUrl: "https://platform.moonshot.cn/console/api-keys",
      },
    ],
    keysUrl: "https://platform.moonshot.ai/console/api-keys",
  },
  {
    id: "kimi-code",
    name: "Kimi Code",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.kimi.ai/coding/v1",
      anthropic_messages: "https://api.kimi.ai/coding",
    },
    defaultProtocol: "openai_chat",
    note: "Membership",
    regions: [
      {
        id: "global",
        name: "Global · api.kimi.ai",
        endpoints: {
          openai_chat: "https://api.kimi.ai/coding/v1",
          anthropic_messages: "https://api.kimi.ai/coding",
        },
      },
      {
        id: "cn",
        name: "China · api.kimi.com",
        endpoints: {
          openai_chat: "https://api.kimi.com/coding/v1",
          anthropic_messages: "https://api.kimi.com/coding",
        },
      },
    ],
    keysUrl: "https://www.kimi.com/code/console",
  },
  {
    id: "zhipu",
    name: "Zhipu GLM",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://open.bigmodel.cn/api/paas/v4",
      anthropic_messages: "https://open.bigmodel.cn/api/anthropic",
    },
    defaultProtocol: "openai_chat",
    regionLabel: "Plan",
    regions: [
      {
        id: "api",
        name: "Pay as you go",
        endpoints: {
          openai_chat: "https://open.bigmodel.cn/api/paas/v4",
          anthropic_messages: "https://open.bigmodel.cn/api/anthropic",
        },
      },
      {
        id: "coding",
        name: "Coding Plan",
        endpoints: {
          openai_chat: "https://open.bigmodel.cn/api/coding/paas/v4",
          openai_responses: "https://open.bigmodel.cn/api/v1",
          anthropic_messages: "https://open.bigmodel.cn/api/anthropic",
        },
      },
    ],
    keysUrl: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys",
  },
  {
    id: "zai",
    name: "Z.ai",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.z.ai/api/paas/v4",
      anthropic_messages: "https://api.z.ai/api/anthropic",
    },
    defaultProtocol: "openai_chat",
    regionLabel: "Plan",
    regions: [
      {
        id: "api",
        name: "Pay as you go",
        endpoints: {
          openai_chat: "https://api.z.ai/api/paas/v4",
          anthropic_messages: "https://api.z.ai/api/anthropic",
        },
      },
      {
        id: "coding",
        name: "Coding Plan",
        endpoints: {
          openai_chat: "https://api.z.ai/api/coding/paas/v4",
          openai_responses: "https://api.z.ai/api/v1",
          anthropic_messages: "https://api.z.ai/api/anthropic",
        },
      },
    ],
    keysUrl: "https://z.ai/manage-apikey/apikey-list",
  },
  {
    id: "minimax",
    name: "MiniMax",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.minimax.io/v1",
      anthropic_messages: "https://api.minimax.io/anthropic",
    },
    defaultProtocol: "openai_chat",
    regions: [
      {
        id: "global",
        name: "Global · api.minimax.io",
        endpoints: {
          openai_chat: "https://api.minimax.io/v1",
          anthropic_messages: "https://api.minimax.io/anthropic",
        },
        keysUrl: "https://platform.minimax.io/user-center/basic-information/interface-key",
      },
      {
        id: "cn",
        name: "China · api.minimaxi.com",
        endpoints: {
          openai_chat: "https://api.minimaxi.com/v1",
          anthropic_messages: "https://api.minimaxi.com/anthropic",
        },
        keysUrl: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
      },
    ],
    keysUrl: "https://platform.minimax.io/user-center/basic-information/interface-key",
  },
  {
    id: "stepfun",
    name: "StepFun",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.stepfun.ai/step_plan/v1",
      anthropic_messages: "https://api.stepfun.ai/step_plan",
    },
    defaultProtocol: "openai_chat",
    regionLabel: "Plan",
    regions: [
      {
        id: "plan-global",
        name: "Step Plan · Global",
        endpoints: {
          openai_chat: "https://api.stepfun.ai/step_plan/v1",
          anthropic_messages: "https://api.stepfun.ai/step_plan",
        },
        keysUrl: "https://platform.stepfun.ai/interface-key",
      },
      {
        id: "plan-cn",
        name: "Step Plan · China",
        endpoints: {
          openai_chat: "https://api.stepfun.com/step_plan/v1",
          anthropic_messages: "https://api.stepfun.com/step_plan",
        },
        keysUrl: "https://platform.stepfun.com/interface-key",
      },
      {
        id: "api-global",
        name: "Pay as you go · Global",
        endpoints: {
          openai_chat: "https://api.stepfun.ai/v1",
          anthropic_messages: "https://api.stepfun.ai",
        },
        keysUrl: "https://platform.stepfun.ai/interface-key",
      },
      {
        id: "api-cn",
        name: "Pay as you go · China",
        endpoints: {
          openai_chat: "https://api.stepfun.com/v1",
          anthropic_messages: "https://api.stepfun.com",
        },
        keysUrl: "https://platform.stepfun.com/interface-key",
      },
    ],
    keysUrl: "https://platform.stepfun.ai/interface-key",
  },
  {
    id: "xiaomi",
    name: "Xiaomi MiMo",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://token-plan-cn.xiaomimimo.com/v1",
      openai_responses: "https://token-plan-cn.xiaomimimo.com/v1",
      anthropic_messages: "https://token-plan-cn.xiaomimimo.com/anthropic",
    },
    defaultProtocol: "openai_chat",
    regionLabel: "Plan",
    regions: [
      {
        id: "plan-cn",
        name: "Plan · China",
        endpoints: {
          openai_chat: "https://token-plan-cn.xiaomimimo.com/v1",
          openai_responses: "https://token-plan-cn.xiaomimimo.com/v1",
          anthropic_messages: "https://token-plan-cn.xiaomimimo.com/anthropic",
        },
      },
      {
        id: "plan-sgp",
        name: "Plan · Singapore",
        endpoints: {
          openai_chat: "https://token-plan-sgp.xiaomimimo.com/v1",
          openai_responses: "https://token-plan-sgp.xiaomimimo.com/v1",
          anthropic_messages: "https://token-plan-sgp.xiaomimimo.com/anthropic",
        },
      },
      {
        id: "plan-ams",
        name: "Plan · Europe",
        endpoints: {
          openai_chat: "https://token-plan-ams.xiaomimimo.com/v1",
          openai_responses: "https://token-plan-ams.xiaomimimo.com/v1",
          anthropic_messages: "https://token-plan-ams.xiaomimimo.com/anthropic",
        },
      },
      {
        id: "api",
        name: "Pay as you go",
        endpoints: {
          openai_chat: "https://api.xiaomimimo.com/v1",
          openai_responses: "https://api.xiaomimimo.com/v1",
          anthropic_messages: "https://api.xiaomimimo.com/anthropic",
        },
      },
    ],
    keysUrl: "https://platform.xiaomimimo.com/token-plan",
  },
  {
    id: "baidu-qianfan",
    name: "Baidu Qianfan",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://qianfan.baidubce.com/v2/tokenplan/personal",
      openai_responses: "https://qianfan.baidubce.com/v2/tokenplan/personal",
      anthropic_messages: "https://qianfan.baidubce.com/anthropic/tokenplan/personal",
    },
    defaultProtocol: "openai_chat",
    regionLabel: "Plan",
    regions: [
      {
        id: "personal",
        name: "Token Plan Personal",
        endpoints: {
          openai_chat: "https://qianfan.baidubce.com/v2/tokenplan/personal",
          openai_responses: "https://qianfan.baidubce.com/v2/tokenplan/personal",
          anthropic_messages: "https://qianfan.baidubce.com/anthropic/tokenplan/personal",
        },
      },
      {
        id: "team",
        name: "Token Plan Enterprise",
        endpoints: {
          openai_chat: "https://qianfan.baidubce.com/v2/tokenplan/team",
          openai_responses: "https://qianfan.baidubce.com/v2/tokenplan/team",
          anthropic_messages: "https://qianfan.baidubce.com/anthropic/tokenplan/team",
        },
      },
      {
        id: "api",
        name: "Pay as you go",
        endpoints: {
          openai_chat: "https://qianfan.baidubce.com/v2",
          openai_responses: "https://qianfan.baidubce.com/v2",
          anthropic_messages: "https://qianfan.baidubce.com/anthropic",
        },
        keysUrl: "https://console.bce.baidu.com/iam/#/iam/apikey/list",
      },
    ],
    keysUrl: "https://console.bce.baidu.com/qianfan/resource/token-plan",
  },
  {
    id: "tencent-cloud",
    name: "Tencent Cloud",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.lkeap.cloud.tencent.com/plan/v3",
      anthropic_messages: "https://api.lkeap.cloud.tencent.com/plan/anthropic",
    },
    defaultProtocol: "openai_chat",
    regionLabel: "Plan",
    regions: [
      {
        id: "plan",
        name: "Plan · China",
        endpoints: {
          openai_chat: "https://api.lkeap.cloud.tencent.com/plan/v3",
          anthropic_messages: "https://api.lkeap.cloud.tencent.com/plan/anthropic",
        },
      },
      {
        id: "cn",
        name: "Pay as you go · China",
        endpoints: {
          openai_chat: "https://tokenhub.tencentmaas.com/v1",
          openai_responses: "https://tokenhub.tencentmaas.com/v1",
          anthropic_messages: "https://tokenhub.tencentmaas.com",
        },
        keysUrl: "https://console.cloud.tencent.com/tokenhub/apikey",
      },
      {
        id: "intl",
        name: "Pay as you go · Global",
        endpoints: {
          openai_chat: "https://tokenhub-intl.tencentmaas.com/v1",
          openai_responses: "https://tokenhub-intl.tencentmaas.com/v1",
          anthropic_messages: "https://tokenhub-intl.tencentmaas.com",
        },
        keysUrl: "https://console.tencentcloud.com/tokenhub/apikey",
      },
    ],
    keysUrl: "https://console.cloud.tencent.com/tokenhub/tokenplan",
  },
  {
    id: "huaweicloud",
    name: "Huawei Cloud MaaS",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.modelarts-maas.com/plan/v2",
      anthropic_messages: "https://api.modelarts-maas.com/plan/anthropic",
    },
    defaultProtocol: "openai_chat",
    note: "西南-贵阳一",
    regionLabel: "Plan",
    regions: [
      {
        id: "plan",
        name: "Token Plan",
        endpoints: {
          openai_chat: "https://api.modelarts-maas.com/plan/v2",
          anthropic_messages: "https://api.modelarts-maas.com/plan/anthropic",
        },
      },
      {
        id: "api",
        name: "Pay as you go",
        endpoints: {
          openai_chat: "https://api.modelarts-maas.com/openai/v1",
          anthropic_messages: "https://api.modelarts-maas.com/anthropic",
        },
      },
    ],
    keysUrl: "https://console.huaweicloud.com/modelarts/?#/model-studio/authmanage",
  },
  {
    id: "volcengine",
    name: "Volcengine Ark",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://ark.cn-beijing.volces.com/api/coding/v3",
      openai_responses: "https://ark.cn-beijing.volces.com/api/coding/v3",
      anthropic_messages: "https://ark.cn-beijing.volces.com/api/coding",
    },
    defaultProtocol: "openai_chat",
    note: "火山方舟",
    regionLabel: "Plan",
    regions: [
      {
        id: "coding",
        name: "Coding Plan",
        endpoints: {
          openai_chat: "https://ark.cn-beijing.volces.com/api/coding/v3",
          openai_responses: "https://ark.cn-beijing.volces.com/api/coding/v3",
          anthropic_messages: "https://ark.cn-beijing.volces.com/api/coding",
        },
      },
      {
        id: "agent",
        name: "Agent Plan",
        endpoints: {
          openai_chat: "https://ark.cn-beijing.volces.com/api/plan/v3",
          openai_responses: "https://ark.cn-beijing.volces.com/api/plan/v3",
          anthropic_messages: "https://ark.cn-beijing.volces.com/api/plan",
        },
      },
      {
        id: "api",
        name: "Pay as you go",
        endpoints: {
          openai_chat: "https://ark.cn-beijing.volces.com/api/v3",
          openai_responses: "https://ark.cn-beijing.volces.com/api/v3",
        },
      },
    ],
    keysUrl: "https://ark.volcengine.com/region:cn-beijing/apikey",
  },
  {
    id: "qwen",
    name: "Qwen",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      anthropic_messages: "https://dashscope-intl.aliyuncs.com/apps/anthropic",
      // Decision models (decision-model-preview): Janus maps dashscope/maas
      // hosts to upstream /systemone. Base preview needs a workspace MaaS
      // host: https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1
      // (public dashscope.aliyuncs.com/…/systemone 404s for the base model).
      openai_decisions: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    },
    defaultProtocol: "openai_chat",
    note: "DashScope",
    regions: [
      {
        id: "intl",
        name: "International",
        endpoints: {
          openai_chat: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
          anthropic_messages: "https://dashscope-intl.aliyuncs.com/apps/anthropic",
          openai_decisions: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        },
        keysUrl: "https://modelstudio.console.alibabacloud.com/?tab=playground#/api-key",
      },
      {
        id: "cn",
        name: "China",
        endpoints: {
          openai_chat: "https://dashscope.aliyuncs.com/compatible-mode/v1",
          anthropic_messages: "https://dashscope.aliyuncs.com/apps/anthropic",
          openai_decisions: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        },
        keysUrl: "https://bailian.console.aliyun.com/?tab=model#/api-key",
      },
    ],
    keysUrl: "https://modelstudio.console.alibabacloud.com/?tab=playground#/api-key",
  },
  {
    id: "qwen-token-plan",
    name: "Qwen Token Plan",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1",
      anthropic_messages: "https://token-plan.maas.qianwenaiapi.com/apps/anthropic",
    },
    defaultProtocol: "openai_chat",
    note: "Bailian · subscription",
    keysUrl: "https://bailian.console.aliyun.com/cn-beijing/subscription/token-plan/personal",
  },
  {
    id: "mistral",
    name: "Mistral",
    kind: "vendor",
    endpoints: { openai_chat: "https://api.mistral.ai/v1" },
    defaultProtocol: "openai_chat",
    keysUrl: "https://console.mistral.ai/api-keys",
  },
  {
    id: "groq",
    name: "Groq",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://api.groq.com/openai/v1",
      openai_responses: "https://api.groq.com/openai/v1",
    },
    defaultProtocol: "openai_chat",
    keysUrl: "https://console.groq.com/keys",
  },
  {
    id: "bedrock",
    name: "Amazon Bedrock",
    kind: "vendor",
    endpoints: bedrockRegions[0].endpoints,
    defaultProtocol: "openai_chat",
    note: "Bedrock API key",
    regionLabel: "Region",
    regions: bedrockRegions,
    keysUrl: "https://console.aws.amazon.com/bedrock/home#/api-keys",
  },
  {
    id: "azure",
    name: "Azure OpenAI",
    kind: "vendor",
    endpoints: {},
    defaultProtocol: "openai_chat",
    note: "your resource's endpoint and key",
    endpointPlaceholder: "https://<resource>.openai.azure.com/openai/v1",
    endpointHint:
      "Your resource's endpoint, from Keys and Endpoint in the Azure portal. The model ids are your deployments' names.",
    keysUrl: "https://ai.azure.com",
  },
  {
    id: "ollama-cloud",
    name: "Ollama Cloud",
    kind: "vendor",
    endpoints: {
      openai_chat: "https://ollama.com/v1",
      anthropic_messages: "https://ollama.com",
    },
    defaultProtocol: "openai_chat",
    note: "cloud models, with an API key",
    keysUrl: "https://ollama.com/settings/keys",
  },

  // ---- relays (aggregators reselling many vendors) ----
  {
    id: "openrouter",
    name: "OpenRouter",
    kind: "relay",
    endpoints: {
      openai_chat: "https://openrouter.ai/api/v1",
      anthropic_messages: "https://openrouter.ai/api",
    },
    defaultProtocol: "openai_chat",
    keysUrl: "https://openrouter.ai/keys",
  },
  {
    id: "together",
    name: "Together AI",
    kind: "relay",
    endpoints: { openai_chat: "https://api.together.xyz/v1" },
    defaultProtocol: "openai_chat",
    keysUrl: "https://api.together.ai/settings/api-keys",
  },
  {
    id: "fireworks",
    name: "Fireworks",
    kind: "relay",
    endpoints: { openai_chat: "https://api.fireworks.ai/inference/v1" },
    defaultProtocol: "openai_chat",
    keysUrl: "https://app.fireworks.ai/settings/users/api-keys",
  },
  {
    id: "siliconflow",
    name: "SiliconFlow",
    kind: "relay",
    endpoints: { openai_chat: "https://api.siliconflow.cn/v1" },
    defaultProtocol: "openai_chat",
    keysUrl: "https://cloud.siliconflow.cn/account/ak",
  },
  {
    id: "nvidia",
    name: "NVIDIA NIM",
    kind: "relay",
    endpoints: { openai_chat: "https://integrate.api.nvidia.com/v1" },
    defaultProtocol: "openai_chat",
    keysUrl: "https://build.nvidia.com/settings/api-keys",
  },
  {
    id: "modelscope",
    name: "ModelScope",
    kind: "relay",
    endpoints: {
      openai_chat: "https://api-inference.modelscope.cn/v1",
      openai_responses: "https://api-inference.modelscope.cn/v1",
    },
    defaultProtocol: "openai_chat",
    note: "魔搭 · API-Inference",
    keysUrl: "https://modelscope.cn/my/myaccesstoken",
  },

  // ---- local servers ----
  {
    id: "ollama",
    name: "Ollama",
    kind: "local",
    endpoints: {
      openai_chat: "http://localhost:11434/v1",
      anthropic_messages: "http://localhost:11434",
    },
    defaultProtocol: "openai_chat",
    note: "your local models — localhost is the gateway host",
    noKey: true,
  },
  {
    id: "lmstudio",
    name: "LM Studio",
    kind: "local",
    endpoints: { openai_chat: "http://localhost:1234/v1" },
    defaultProtocol: "openai_chat",
    note: "local server on :1234 — localhost is the gateway host",
    noKey: true,
  },
  {
    id: "omlx",
    name: "oMLX",
    kind: "local",
    endpoints: {
      openai_chat: "http://localhost:8000/v1",
      openai_responses: "http://localhost:8000/v1",
      anthropic_messages: "http://localhost:8000",
    },
    defaultProtocol: "openai_chat",
    note: "local server on :8000 — localhost is the gateway host",
    noKey: true,
  },
]
