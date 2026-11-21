using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;

namespace AirMicHub.Server;

internal static class HttpUtil
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static async Task WriteBytesAsync(
        HttpContext context,
        byte[] body,
        string? contentType,
        int statusCode = StatusCodes.Status200OK,
        bool noStore = true,
        IReadOnlyDictionary<string, string>? extraHeaders = null)
    {
        context.Response.StatusCode = statusCode;
        if (!string.IsNullOrEmpty(contentType))
        {
            context.Response.ContentType = contentType;
        }
        context.Response.ContentLength = body.Length;
        if (noStore)
        {
            context.Response.Headers.CacheControl = "no-store, no-cache, must-revalidate";
        }
        context.Response.Headers["X-Content-Type-Options"] = "nosniff";
        context.Response.Headers["Referrer-Policy"] = "no-referrer";

        if (extraHeaders is not null)
        {
            foreach (var (key, value) in extraHeaders)
            {
                context.Response.Headers[key] = value;
            }
        }

        if (HttpMethods.IsHead(context.Request.Method)) return;
        await context.Response.Body.WriteAsync(body, context.RequestAborted);
    }

    public static Task WriteJsonAsync(HttpContext context, object payload, IReadOnlyDictionary<string, string>? extraHeaders = null)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions);
        return WriteBytesAsync(context, bytes, "application/json; charset=utf-8", extraHeaders: extraHeaders);
    }

    public static Task WriteTextAsync(HttpContext context, int statusCode, string message)
    {
        return WriteBytesAsync(
            context,
            Encoding.UTF8.GetBytes(message),
            "text/plain; charset=utf-8",
            statusCode);
    }

    public static bool IsWebSocketUpgrade(HttpContext context) => context.WebSockets.IsWebSocketRequest;
}
