// opencode plugin: authenticate the `azure` model provider to Azure OpenAI / AI
// Foundry KEYLESS, using the pod's Entra Workload Identity.
//
// @azure/identity's DefaultAzureCredential auto-detects the workload-identity env the
// AKS webhook injects (AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE)
// when the pod's ServiceAccount is annotated `azure.workload.identity/client-id` and
// the pod is labeled `azure.workload.identity/use: "true"`. It mints an AAD access
// token for Cognitive Services and refreshes it transparently (the projected SA token
// is re-read on each call). We wrap the provider's `fetch` so every request carries
// `Authorization: Bearer <token>` instead of the `api-key` header — so no API key is
// ever stored. The dummy `apiKey` in opencode.json only satisfies SDK construction;
// this fetch wrapper strips it.
import { DefaultAzureCredential, getBearerTokenProvider } from "@azure/identity"

// Load-bearing: must match the Workload Identity scope the UAI is granted
// (Cognitive Services OpenAI User on the Foundry account).
const SCOPE = "https://cognitiveservices.azure.com/.default"

export const AzureBrainAuth = async () => {
  const getToken = getBearerTokenProvider(new DefaultAzureCredential(), SCOPE)
  return {
    // The `config` hook runs before opencode instantiates the provider, so mutating
    // provider.azure.options here is honoured by the @ai-sdk/azure factory.
    config: async (cfg: any) => {
      const az = cfg?.provider?.azure
      if (!az) return
      az.options = az.options ?? {}
      const base = az.options.fetch ?? globalThis.fetch
      az.options.fetch = async (input: any, init: any = {}) => {
        const headers = new Headers(init.headers)
        headers.set("Authorization", `Bearer ${await getToken()}`)
        headers.delete("api-key")
        return base(input, { ...init, headers })
      }
    },
  }
}
