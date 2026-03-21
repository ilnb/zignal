# Zignal

A simple LAN chatting server written in Zig.

## Features
- Basic runtime client identification
- Server to client communication
- Client to client communication
- Persistent client identity (token-based)
- Multi-profile support

## Usage

### Server
```sh
zig-out/bin/server [options]
```

### Client
```sh
zig-out/bin/client [options]
```

### Options
| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--port` | `-p` | `8000` | Port to use |
| `--profile` | `-P` | `default` | Profile to use |
| `--help` | `-h` | | Display help |

Profiles distinguish between multiple server/client instances. A client connects to the server sharing the same port, and is identified across sessions by its profile's stored token.

## Client Side commands:

- `ECHO` - Echo your message from server, e.g., `ECHO <msg>`
- `WHOAMI` - To get your own details
- `NAME` - To set/update your name, e.g., `NAME <name>`
- `GETINFO` - To get the details of one/all clients on the server, e.g., `GETINFO <id/name?>`
- `LINK` - To connect to another client, e.g., `LINK <id/name>`
- `UNLINK` - To disconnect from another client, e.g., `UNLINK <id/name>`
- `SENDTO` - To send message to a specified client of the your links, e.g., `SENDTO <id/name> <msg>`
- `ALL` - To broadcast a message to all your links, e.g., `ALL <msg>`

## TODO:
- Server side commands
- Group chats
- Message history
- Thread Pool
- A Front End
