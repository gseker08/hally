using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Unicode;
using Hally.Domain.Common;
using Hally.Domain.Sharing;

namespace Hally.Api.Features.Sharing;

/// <summary>Renders the helper page. Every dynamic value is HTML-encoded.</summary>
public static class SharedPage
{
    public record Item(Guid Id, string Title, DateTimeOffset? At, bool AllDay, bool Done, string? Location = null);

    public record Model(string AppName, string SharerFirstName, ShareLinkKind Kind, string Lang, string TimeZoneId, DateOnly? Day,
        IReadOnlyList<Item> Tasks, IReadOnlyList<Item> Events, DateTimeOffset ExpiresAt);

    // Encodes markup characters but keeps Turkish letters readable in the page source.
    private static readonly HtmlEncoder Html = HtmlEncoder.Create(UnicodeRanges.All);

    public static string Render(Model m, string basePath)
    {
        var culture = Texts.Culture(m.Lang);
        string T(string key) => Texts.Get(m.Lang, key);
        var longDay = T("format.longDay");
        string When(Item i)
        {
            if (i.At is not { } at)
            {
                return "";
            }

            var local = FamilyTimeZone.ToFamilyTime(at, m.TimeZoneId);
            var date = local.ToString(longDay, culture);
            return m.Kind == ShareLinkKind.Day ? (i.AllDay ? T("page.allDay") : local.ToString("HH:mm")) : i.AllDay ? date : $"{date} · {local:HH:mm}";
        }

        var title = m.Kind == ShareLinkKind.Day && m.Day is { } d
            ? d.ToString(longDay, culture)
            : T("page.sharedTask");
        var sb = new StringBuilder();
        sb.Append($"<p class=\"from\">{Html.Encode(Texts.Get(m.Lang, "page.sharedBy", ("name", m.SharerFirstName)))}</p>");
        sb.Append($"<h1>{Html.Encode(title)}</h1>");

        if (m.Events.Count > 0)
        {
            sb.Append($"<h2>{T("page.events")}</h2><ul>");
            foreach (var e in m.Events)
            {
                sb.Append($"<li><span class=\"t\">{Html.Encode(e.Title)}</span><span class=\"w\">{Html.Encode(When(e))}{(e.Location is null ? "" : " · " + Html.Encode(e.Location))}</span></li>");
            }

            sb.Append("</ul>");
        }

        if (m.Tasks.Count > 0)
        {
            sb.Append($"<h2>{T("page.todo")}</h2><ul>");
            foreach (var t in m.Tasks)
            {
                sb.Append($"<li class=\"{(t.Done ? "done" : "")}\"><span class=\"t\">{Html.Encode(t.Title)}</span><span class=\"w\">{Html.Encode(When(t))}</span>");
                sb.Append(t.Done
                    ? $"<span class=\"ok\">✓ {T("page.done")}</span>"
                    : $"<form method=\"post\" action=\"{Html.Encode($"{basePath}/tasks/{t.Id}/done")}\"><button type=\"submit\">{T("page.markDone")}</button></form>");
                sb.Append("</li>");
            }

            sb.Append("</ul>");
        }

        if (m.Tasks.Count == 0 && m.Events.Count == 0)
        {
            sb.Append($"<p class=\"empty\">{T("page.empty")}</p>");
        }

        var expires = FamilyTimeZone.ToFamilyTime(m.ExpiresAt, m.TimeZoneId).ToString(T("format.expires"), culture);
        sb.Append($"<p class=\"foot\">{Html.Encode(Texts.Get(m.Lang, "page.expires", ("date", expires)))}</p>");
        return Layout(m.AppName, Html.Encode(title), sb.ToString(), m.Lang);
    }

    public static string Gone(string appName, string lang) => Layout(appName, Texts.Get(lang, "page.gone.title"),
        $"<h1>{Texts.Get(lang, "page.gone.heading")}</h1><p class=\"empty\">{Texts.Get(lang, "page.gone.body")}</p>",
        lang);

    private static string Layout(string appName, string title, string body, string lang) => $$$"""
        <!doctype html>
        <html lang="{{{lang}}}">
        <head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex">
        <title>{{{title}}} · {{{Html.Encode(appName)}}}</title>
        <style>
        :root{--bg:#FBF5F6;--card:#fff;--ink:#231A1D;--muted:#625A5E;--brand:#A8133C;--ok:#23937A;--line:#F0E4E7;--onbrand:#fff}
        @media (prefers-color-scheme:dark){:root{--bg:#1A1215;--card:#251B1F;--ink:#F6EEF0;--muted:#B5A9AE;--brand:#E25C7C;--line:#3A2A2F;--onbrand:#1A1215}}
        *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
        main{max-width:560px;margin:0 auto;padding:24px 16px 40px}
        .brand{font-weight:800;color:var(--brand);letter-spacing:.3px}
        h1{font-size:26px;line-height:1.2;margin:6px 0 18px}h2{font-size:14px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin:22px 0 8px}
        ul{list-style:none;margin:0;padding:0}li{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px 16px;margin-bottom:10px;display:flex;flex-direction:column;gap:4px}
        .t{font-weight:600}.w{color:var(--muted);font-size:14px}.from{color:var(--muted);margin:16px 0 0}
        li.done .t{text-decoration:line-through;color:var(--muted)}.ok{color:var(--ok);font-weight:600;font-size:14px}
        form{margin:6px 0 0}button{font:inherit;font-weight:600;border:0;border-radius:999px;padding:10px 16px;background:var(--brand);color:var(--onbrand);cursor:pointer;width:100%}
        .empty,.foot{color:var(--muted)}.foot{font-size:13px;margin-top:28px}
        </style>
        </head>
        <body><main><div class="brand">{{{Html.Encode(appName)}}}</div>{{{body}}}</main></body>
        </html>
        """;
}
