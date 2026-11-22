using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using FluentAssertions;
using Microsoft.AspNetCore.Http.Connections;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record ChatMessageEventBody(Guid FamilyId, string ChatKey, MessageBody Message);

/// <summary>The live channel: a message stored through the REST API reaches the other adults' connections at once.</summary>
[Collection(ApiCollection.Name)]
public class ChatHubTests(HallyApiFactory api)
{
    private HubConnection Connect(HttpClient signedIn, List<ChatMessageEventBody> received)
    {
        var token = signedIn.DefaultRequestHeaders.Authorization!.Parameter;
        var connection = new HubConnectionBuilder()
            .WithUrl(new Uri(api.Server.BaseAddress, "hubs/chat"), o =>
            {
                // The in-memory test server has no real sockets, so use long polling through its handler.
                o.Transports = HttpTransportType.LongPolling;
                o.HttpMessageHandlerFactory = _ => api.Server.CreateHandler();
                o.AccessTokenProvider = () => Task.FromResult(token);
            })
            .AddJsonProtocol(o => o.PayloadSerializerOptions.Converters.Add(new JsonStringEnumConverter()))
            .Build();
        connection.On<ChatMessageEventBody>("MessageReceived", e =>
        {
            lock (received)
            {
                received.Add(e);
            }
        });
        return connection;
    }

    private static async Task Eventually(Func<bool> condition)
    {
        for (var i = 0; i < 50 && !condition(); i++)
        {
            await Task.Delay(100);
        }

        condition().Should().BeTrue();
    }

    [Fact]
    public async Task A_direct_message_reaches_both_adults_with_their_own_chat_key()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Aile" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var ownerId = (await owner.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id;
        var partnerId = (await partner.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id;
        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Yabancı");

        var toOwner = new List<ChatMessageEventBody>();
        var toPartner = new List<ChatMessageEventBody>();
        var toStranger = new List<ChatMessageEventBody>();
        await using var ownerConn = Connect(owner, toOwner);
        await using var partnerConn = Connect(partner, toPartner);
        await using var strangerConn = Connect(stranger, toStranger);
        await Task.WhenAll(ownerConn.StartAsync(), partnerConn.StartAsync(), strangerConn.StartAsync());

        (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/chats/{partnerId}/messages", new { body = "Okuldan sen alır mısın?" }))
            .StatusCode.Should().Be(HttpStatusCode.Created);

        await Eventually(() => toPartner.Count == 1 && toOwner.Count == 1);
        toPartner[0].ChatKey.Should().Be(ownerId.ToString(), "the partner sees this chat under the owner's id");
        toPartner[0].Message.Body.Should().Be("Okuldan sen alır mısın?");
        toPartner[0].FamilyId.Should().Be(family.Id);
        toOwner[0].ChatKey.Should().Be(partnerId.ToString(), "the sender's other devices update too");

        await Task.Delay(300);
        toStranger.Should().BeEmpty();
    }

    [Fact]
    public async Task The_hub_refuses_connections_without_a_token()
    {
        var connection = new HubConnectionBuilder()
            .WithUrl(new Uri(api.Server.BaseAddress, "hubs/chat"), o =>
            {
                o.Transports = HttpTransportType.LongPolling;
                o.HttpMessageHandlerFactory = _ => api.Server.CreateHandler();
            })
            .Build();
        var act = () => connection.StartAsync();
        (await act.Should().ThrowAsync<HttpRequestException>()).Which.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        await connection.DisposeAsync();
    }
}
