# Bootstrap Secrets Manifest

**Goal:** manter credenciais locais por host, com varias chaves por provedor, validacao antes de aplicar e troca manual segura pela fila.

## Contexto

O bootstrap ja provisiona CLIs, IDEs e clientes desktop, mas ainda dependia de uma chave unica por provedor. Isso criava atrito quando uma key expirava, estourava cota ou precisava ser trocada sem perder o resto da configuracao do host.

## Objetivo

- Criar um manifesto local versionado em schema v2.
- Suportar varias credenciais nomeadas por provedor.
- Manter `activeCredential` e `rotationOrder`.
- Validar a credencial ativa antes de aplicar env vars e arquivos de clientes.
- Importar notas/Markdown brutos para o manifesto local sem subir segredos ao Git.

## Nao Objetivos

- Nao criptografar segredos nesta etapa.
- Nao sincronizar com cloud vault.
- Nao fazer failover automatico dentro dos apps em tempo real.
- Nao guardar URLs, paths locais e notas gerais no manifesto final.

## Local do Manifesto

O bootstrap resolve o arquivo nesta ordem:

1. `BOOTSTRAP_DATA_ROOT`, se definido.
2. `~\.bootstrap-tools`
3. `%LOCALAPPDATA%\bootstrap-tools`
4. `%TEMP%\bootstrap-tools`
5. `.\.bootstrap-tools`

Arquivo esperado:

- `bootstrap-secrets.json`

Esse arquivo continua local-only e fica coberto pelo ignore do repositorio.

## Estrutura v2

```json
{
  "$schema": "https://bootstrap.local/schemas/bootstrap-secrets.schema.json",
  "metadata": {
    "version": 2,
    "description": "Credenciais locais do host",
    "notes": [
      "Use credentials para armazenar varias chaves por provedor.",
      "activeCredential aponta para a chave atualmente aplicada.",
      "rotationOrder define a fila manual de troca."
    ]
  },
  "providers": {
    "openrouter": {
      "defaults": {
        "baseUrl": "https://openrouter.ai/api/v1"
      },
      "activeCredential": "openrouter-gmail-01",
      "rotationOrder": [
        "openrouter-gmail-01",
        "openrouter-usa-01"
      ],
      "credentials": {
        "openrouter-gmail-01": {
          "displayName": "Gmail",
          "secret": "sk-or-v1-...",
          "secretKind": "apiKey",
          "validation": {
            "state": "passed",
            "checkedAt": "2026-04-18T21:00:00Z",
            "message": "ok"
          }
        },
        "openrouter-usa-01": {
          "displayName": "USA",
          "secret": "sk-or-v1-...",
          "secretKind": "apiKey",
          "validation": {
            "state": "unknown",
            "checkedAt": "",
            "message": ""
          }
        }
      }
    }
  },
  "targets": {
    "userEnv": {
      "OPENROUTER_API_KEY": "{{activeProviders.openrouter.apiKey}}",
      "OPENROUTER_BASE_URL": "{{activeProviders.openrouter.baseUrl}}"
    }
  }
}
```

## Regras

- Manifestos v1 sao migrados automaticamente para v2.
- Placeholders `{{activeProviders.*}}` e `{{providers.*}}` resolvem a credencial ativa validada.
- Valores vazios nao sao aplicados.
- Credenciais com `validation.state != passed` nao sao reaplicadas nos targets.
- Itens sem validador confiavel entram como `unsupported/manual-review`.
- `rotationOrder` preserva a fila manual definida pelo usuario/importador.
- A camada de MCPs gerenciados e opt-in no resolvedor; `bootstrap-secrets` nao mistura esse catalogo por padrao.

## Validacao

Validadores dedicados nesta etapa:

- `openai`
- `anthropic`
- `google`
- `openrouter`
- `github`
- `moonshot`
- `deepseek`

Tratamento especial:

- `bonsai`: catalogado, mas cai em `unsupported/manual-review` ate existir um probe confiavel
- `context7`, `firecrawl`, `apify`, `netdata`, `supabase`: podem ser consumidos pela camada de MCPs gerenciados com bypass manual/local quando o host tem uma credencial ativa utilizavel, mesmo sem probe remoto confiavel nesta fase

## Operacoes de CLI

```powershell
.\bootstrap-tools.ps1 -SecretsList
.\bootstrap-tools.ps1 -SecretsValidateAll
.\bootstrap-tools.ps1 -SecretsImportPath "C:\caminho\credenciais.md"
.\bootstrap-tools.ps1 -SecretsActivateProvider openrouter
.\bootstrap-tools.ps1 -SecretsActivateCredential openrouter-gmail-01
```

Comportamento:

- `-SecretsList`: lista provider/id/status sem exibir o segredo.
- `-SecretsValidateAll`: revalida todas as credenciais suportadas.
- `-SecretsImportPath`: importa tokens de Markdown/texto, deduplica por provedor e tenta eleger a primeira credencial valida.
- `-SecretsActivateProvider`: gira para a proxima credencial valida na fila manual.
- `-SecretsActivateCredential`: tenta ativar uma credencial especifica; se falhar na validacao, a ativa atual permanece.

## Fluxo Esperado

1. Rodar `bootstrap-secrets` para garantir o manifesto local.
2. Importar ou preencher credenciais.
3. Validar.
4. Aplicar somente as credenciais ativas e aprovadas.
5. Quando uma key falhar, usar a fila manual para trocar com seguranca.

## MCPs Gerenciados

O componente `bootstrap-mcps` consome o mesmo manifesto local, mas faz uma resolucao enriquecida para mesclar MCPs locais/remotos nos targets compatíveis sem alterar o comportamento padrao de `bootstrap-secrets`.

Catalogo inicial:

- `GitHub MCP Server`
- `Markitdown`
- `Netdata`
- `Context7`
- `Chrome DevTools MCP`
- `Playwright`
- `Serena`
- `Firecrawl`
- `Desktop Commander`
- `Notion`
- `Supabase`
- `Figma MCP Server`
- `Apify`
- `Vercel MCP`
- `Box MCP Server (Remote)`

Regras operacionais:

- MCPs locais usam `npx` ou `uv tool`, conforme o fornecedor.
- MCPs remotos usam `mcp-remote@latest`.
- Targets explicitos do usuario nao sao sobrescritos; o catalogo gerenciado apenas preenche os nomes que ainda nao existem.
- O estado local fica em `.bootstrap-tools/bootstrap-mcp-state.json`.

## Extensoes Futuras

- Vault opcional.
- Segredos por projeto/workspace.
- Mais validadores de provedores.
- Relatorio detalhado por target aplicado.
