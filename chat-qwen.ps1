#Requires -Version 5.1
<#
.SYNOPSIS
  调用 qwen36-35b-oa 大模型进行交互式问答

.DESCRIPTION
  Windows PowerShell 脚本，通过 ais-v2 chat/completions 接口多轮对话。
  输入 exit / quit / 退出 结束；输入 clear / 清空 重置上下文。

.EXAMPLE
  .\chat-qwen.ps1
  .\chat-qwen.ps1 -Question "用一句话介绍量子计算"
  .\chat-qwen.ps1 -Stream
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Question,

    [switch]$Stream,

    [string]$SystemPrompt = "你是一个有帮助的中文助手，回答简洁准确。"
)

$ErrorActionPreference = "Stop"

$ApiUrl   = "http://43.68.1.14:8080/apis/ais-v2/chat/completions"
$ApiKey   = "sk-7c6e1cf2-5b22-44d4-633c-bb8d9271b6f2"
$Model    = "qwen36-35b-oa"
$TimeoutSec = 120

# TLS / 编码（部分 Windows 环境需要）
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    $OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch {}

function Escape-JsonString([string]$Text) {
    if ($null -eq $Text) { return "" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"') }
            '\'  { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                $code = [int][char]$ch
                if ($code -lt 0x20) {
                    [void]$sb.AppendFormat('\u{0:x4}', $code)
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    return $sb.ToString()
}

function Build-ChatRequestBody {
    param(
        [Parameter(Mandatory)]
        [object[]]$Messages,
        [bool]$UseStream = $false
    )

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($m in @($Messages)) {
        $role = Escape-JsonString ([string]$m.role)
        $content = Escape-JsonString ([string]$m.content)
        $parts.Add("{`"role`":`"$role`",`"content`":`"$content`"}")
    }
    $messagesJson = "[" + ($parts -join ",") + "]"
    $streamJson = if ($UseStream) { "true" } else { "false" }
    return "{`"model`":`"$(Escape-JsonString $Model)`",`"messages`":$messagesJson,`"temperature`":0.7,`"stream`":$streamJson}"
}

function Invoke-ChatCompletion {
    param(
        [Parameter(Mandatory)]
        [object[]]$Messages,

        [bool]$UseStream = $false
    )

    $jsonBody = Build-ChatRequestBody -Messages $Messages -UseStream $UseStream
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

    $headers = @{
        "Authorization" = "Bearer $ApiKey"
        "Content-Type"  = "application/json; charset=utf-8"
        "Accept"        = if ($UseStream) { "text/event-stream" } else { "application/json" }
    }

    if (-not $UseStream) {
        $response = Invoke-RestMethod `
            -Uri $ApiUrl `
            -Method Post `
            -Headers $headers `
            -Body $bodyBytes `
            -TimeoutSec $TimeoutSec

        if ($null -eq $response.choices -or $response.choices.Count -eq 0) {
            throw "接口返回异常：未找到 choices。原始响应：$(($response | ConvertTo-Json -Depth 10))"
        }

        $content = $response.choices[0].message.content
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw "接口返回空内容。原始响应：$(($response | ConvertTo-Json -Depth 10))"
        }
        return [string]$content
    }

    # 流式输出（SSE）
    $request = [System.Net.HttpWebRequest]::Create($ApiUrl)
    $request.Method = "POST"
    $request.ContentType = "application/json; charset=utf-8"
    $request.Accept = "text/event-stream"
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.Headers.Add("Authorization", "Bearer $ApiKey")
    $request.ContentLength = $bodyBytes.Length

    $reqStream = $request.GetRequestStream()
    $reqStream.Write($bodyBytes, 0, $bodyBytes.Length)
    $reqStream.Close()

    $httpResponse = $request.GetResponse()
    $reader = New-Object System.IO.StreamReader($httpResponse.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $fullText = New-Object System.Text.StringBuilder

    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if (-not $line.StartsWith("data:")) { continue }

            $data = $line.Substring(5).Trim()
            if ($data -eq "[DONE]") { break }

            try {
                $chunk = $data | ConvertFrom-Json
            } catch {
                continue
            }

            $delta = $null
            if ($chunk.choices -and $chunk.choices.Count -gt 0) {
                $delta = $chunk.choices[0].delta.content
                if (-not $delta) {
                    $delta = $chunk.choices[0].message.content
                }
            }
            if ($delta) {
                Write-Host -NoNewline $delta
                [void]$fullText.Append($delta)
            }
        }
    }
    finally {
        $reader.Close()
        $httpResponse.Close()
    }

    Write-Host ""
    return $fullText.ToString()
}

function Show-Banner {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Qwen 问答助手  ($Model)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "命令: exit/quit/退出 结束 | clear/清空 重置上下文" -ForegroundColor DarkGray
    Write-Host ""
}

$messages = @(
    @{ role = "system"; content = $SystemPrompt }
)

function Ask-Once([string]$UserText) {
    $script:messages += @{ role = "user"; content = $UserText }

    Write-Host ""
    Write-Host "助手: " -ForegroundColor Green -NoNewline
    if (-not $Stream) { Write-Host "" }

    try {
        $answer = Invoke-ChatCompletion -Messages $script:messages -UseStream:$Stream
        if (-not $Stream) {
            Write-Host $answer
        }
        $script:messages += @{ role = "assistant"; content = $answer }
    }
    catch {
        # 失败时撤回本轮用户消息，避免脏上下文
        if ($script:messages.Count -gt 0) {
            $script:messages = @($script:messages[0..($script:messages.Count - 2)])
        }
        Write-Host ""
        Write-Host "调用失败: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) {
            Write-Host $_.ErrorDetails.Message -ForegroundColor DarkRed
        }
    }
    Write-Host ""
}

# 单次提问模式
if (-not [string]::IsNullOrWhiteSpace($Question)) {
    Ask-Once $Question
    exit 0
}

# 交互模式
Show-Banner
while ($true) {
    Write-Host "你: " -ForegroundColor Yellow -NoNewline
    $inputText = Read-Host
    if ($null -eq $inputText) { continue }

    $trimmed = $inputText.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

    switch -Regex ($trimmed.ToLower()) {
        '^(exit|quit|q|退出)$' {
            Write-Host "再见。" -ForegroundColor Cyan
            break
        }
        '^(clear|cls|清空|重置)$' {
            $script:messages = @(
                @{ role = "system"; content = $SystemPrompt }
            )
            Write-Host "上下文已清空。" -ForegroundColor DarkGray
            Write-Host ""
            continue
        }
        default {
            Ask-Once $trimmed
        }
    }

    if ($trimmed -match '^(exit|quit|q|退出)$') { break }
}
