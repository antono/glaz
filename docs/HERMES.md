# Connecting the Assistant to Hermes Agent

The glasses' **Assistant** sends your question to an AI agent and shows the
answer on the lens. The phone does the talking: it turns your voice into
text, asks the agent over the network, and passes the answer to the
glasses. The agent can be any server that speaks the OpenAI chat API. This
page sets it up with [Hermes Agent](https://hermes-agent.nousresearch.com),
running on a computer of yours, and [Tailscale](https://tailscale.com) to
let the phone reach that computer from anywhere.

You need:

- Hermes Agent installed on a computer that stays on (a home server, a
  desktop, a VPS);
- Tailscale on that computer and on the phone, both signed in to the same
  tailnet;
- glaz on the phone, and the Assistant app on the glasses.

## 1. Turn on Hermes' API server

Hermes has an OpenAI-compatible API server, off by default
([Hermes docs: API server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server)).
Add to `~/.hermes/.env` on the computer:

```sh
API_SERVER_ENABLED=true
API_SERVER_KEY=<a long random string>   # e.g. from: openssl rand -hex 32
# API_SERVER_PORT=8642                  # the default
# API_SERVER_HOST=127.0.0.1             # the default: this computer only
```

Start it:

```sh
hermes gateway
# [API Server] API server listening on http://127.0.0.1:8642
```

Check it on the computer itself:

```sh
curl http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"What is 137 + 1?"}]}'
```

## 2. Let the phone reach it

Pick one. **Option A** suits almost everyone.

### Option A: `tailscale serve` (recommended)

Tailscale publishes the port on your tailnet as HTTPS, with a real
certificate, and Hermes keeps listening on `127.0.0.1` only. Nothing
outside your tailnet can reach it.

In the [Tailscale admin console](https://login.tailscale.com/admin/dns),
turn on **MagicDNS** and **HTTPS certificates** once. Then, on the computer:

```sh
tailscale serve --bg 8642
```

It prints the address, something like `https://hermes.tail1234.ts.net`.
`--bg` keeps it on across reboots; `tailscale serve status` shows it, and
`tailscale serve reset` turns it off.
([Tailscale docs: serve](https://tailscale.com/kb/1242/tailscale-serve))

**Server** in glaz: `https://hermes.tail1234.ts.net`

### Option B: plain HTTP on the tailnet

No HTTPS certificates needed: Hermes listens on the computer's Tailscale
address and the phone connects to port 8642 directly. The traffic is still
encrypted, by Tailscale's WireGuard tunnel. glaz allows plain `http://`
only for `*.ts.net` names, so use the MagicDNS name, not the `100.x.y.z`
address.

In `~/.hermes/.env`:

```sh
API_SERVER_HOST=100.x.y.z   # this computer's address: tailscale ip -4
```

Restart `hermes gateway`. Binding to the Tailscale address keeps Hermes
off your local network; `0.0.0.0` would open it there too. If Hermes starts
before Tailscale is up, it cannot bind to that address: start it after
Tailscale (with systemd, `After=tailscaled.service`). A firewall on the
computer has to let port 8642 in on the `tailscale0` interface.

**Server** in glaz: `http://hermes.tail1234.ts.net:8642`

### Option C: `tailscale funnel` (phone without Tailscale)

Funnel puts the server **on the public internet**, so the phone needs no
Tailscale app. The API key is then the only thing keeping strangers out:
make it long and random, and prefer Options A or B if you can.

```sh
tailscale funnel --bg 8642
```

Funnel has to be allowed for the computer in the tailnet's access policy
the first time; the command says how.
([Tailscale docs: funnel](https://tailscale.com/kb/1311/tailscale-funnel))

**Server** in glaz: `https://hermes.tail1234.ts.net`

### Not supported: a LAN address

`http://192.168.1.137:8642` does not work: Android, and glaz's network
settings, allow plain HTTP only on `*.ts.net`. On a home network without
Tailscale, put Hermes behind a reverse proxy with an HTTPS certificate.

## 3. Set up glaz

On the phone, open **More > Services** and tap **AI agent** (its switch
is on by default). Its page has:

| Field | Value |
| --- | --- |
| Server | the address from step 2; with or without `/v1` at the end |
| Key | `API_SERVER_KEY` from `~/.hermes/.env` |
| Model | `hermes-agent` |

Everything here stays on the phone; none of it goes to the glasses. Both
Assistant and Factchecker ask this agent, and have no switches of their
own: switching AI agent off stops both. Their pages in the Menu tab show
it in a row, **AI agent**, which opens this same page. Under the settings
it lists the requests, the newest 50: which app asked, when, how long the
answer took, and its start or what went wrong -- the first place to look
when the glasses wait in vain. On
**Menu > Assistant**, pick the language you will ask in, and whether
answers are read aloud (headphones only).

Then on the glasses: **Apps > Assistant**, tap, ask, tap again.

## What the agent can do on the glasses

Hermes runs its own tools on its own computer. glaz adds what only the
phone and the glasses can do, as commands the agent writes in its answer:
open an app on the glasses, change an app's setting, take a photo with the
glasses, look through the photos and recordings and their transcripts. glaz
explains these to the agent in the system prompt with every question;
nothing needs setting up in Hermes. **Menu > Assistant > Photos and
recordings** turns the photo and recording access off. The details are in
[PROTOCOL.md, "Assistant"](PROTOCOL.md#assistant).

## When it does not work

The Assistant shows what went wrong on the glasses, and **More > Log**
(Assistant) on the phone has the whole story.

| On the glasses | Check |
| --- | --- |
| `cannot reach the agent` | Tailscale is on on the phone; `hermes gateway` is running; the Server address is right. Open the Server address in the phone's browser: any page, even an error, means it is reachable; a timeout means it is not. |
| `the agent refused the key (401)` | Key in glaz is `API_SERVER_KEY` exactly, no spaces. |
| `the server sends elsewhere (301)` | An `http://` address for an HTTPS server, or the other way round: use the address the message names. |
| `agent error 404` | Server points at the wrong place: the host and port only, or ending in `/v1`. |
| `no answer in 120 s` | Hermes took too long, running tools; try a simpler question, or check Hermes' own log. |
| `Cleartext HTTP traffic ... not permitted` | Plain `http://` to a name outside `*.ts.net`: use the MagicDNS name (Option B) or HTTPS (Option A). |
