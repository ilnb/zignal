# Zignal

A simple LAN chatting server written in Zig.

- [x] Basic server setup
- [x] Basic runtime client identification
- [x] Server to client communication
- [x] Client to client communication
- [ ] Group chats
- [ ] Message history
- [ ] Thread Pool
- [ ] A Front End

## Client Side commands:

- ECHO - Echo your message from server, e.g., ECHO \<msg\>
- WHOAMI - To get your own details
- NAME - To set/update your name, e.g., NAME \<name\>
- GETINFO - To get the details of one/all clients on the server, e.g., GETINFO <id/name?>
- LINK - To connect to another client, e.g., LINK <id/name>
- UNLINK - To disconnect from another client, e.g., UNLINK <id/name>
- SENDTO - To send message to a specified client of the your links, e.g., SENDTO <id/name> \<msg\>
- ALL - To broadcast a message to all your links, e.g., ALL \<msg\>
