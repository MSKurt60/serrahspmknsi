const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const { nanoid } = require('nanoid');
const path = require('path');

const app = express();
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: '*' } });

// Serve static client
app.use(express.static(path.join(__dirname, 'public')));

// In-memory user registry
/**
 * usersById: Map<userId, {
 *   userId: string,
 *   name: string,
 *   status: 'online' | 'dnd' | 'offline',
 *   socketId: string,
 *   blockedUserIds: Set<string>,
 *   lastSeen: number
 * }>
 */
const usersById = new Map();
const socketIdToUserId = new Map();

function publicUser(user) {
  return {
    userId: user.userId,
    name: user.name,
    status: user.status,
    lastSeen: user.lastSeen,
  };
}

function broadcastPlayers() {
  const players = Array.from(usersById.values()).map(publicUser);
  io.emit('players:list', players);
}

io.on('connection', (socket) => {
  // Register/login
  socket.on('register', (payload, ack) => {
    try {
      const desiredName = (payload && payload.name ? String(payload.name) : 'Guest').slice(0, 32);
      let userId = payload && payload.userId ? String(payload.userId) : null;

      // If coming back with known id, reuse it; else create
      let user;
      if (userId && usersById.has(userId)) {
        user = usersById.get(userId);
        user.name = desiredName || user.name;
        user.status = 'online';
        user.socketId = socket.id;
        user.lastSeen = Date.now();
      } else {
        userId = nanoid(10);
        user = {
          userId,
          name: desiredName || `User_${userId}`,
          status: 'online',
          socketId: socket.id,
          blockedUserIds: new Set(),
          lastSeen: Date.now(),
        };
        usersById.set(userId, user);
      }

      socketIdToUserId.set(socket.id, user.userId);
      ack && ack({ ok: true, user: publicUser(user) });
      broadcastPlayers();
    } catch (err) {
      ack && ack({ ok: false, error: 'register_failed' });
    }
  });

  socket.on('set:status', (status) => {
    const userId = socketIdToUserId.get(socket.id);
    if (!userId) return;
    const user = usersById.get(userId);
    if (!user) return;
    if (status !== 'online' && status !== 'dnd') return;
    user.status = status;
    user.lastSeen = Date.now();
    io.emit('player:updated', publicUser(user));
  });

  socket.on('block:user', (targetUserId, ack) => {
    const userId = socketIdToUserId.get(socket.id);
    if (!userId) return ack && ack({ ok: false, error: 'not_registered' });
    const actor = usersById.get(userId);
    if (!usersById.has(targetUserId)) return ack && ack({ ok: false, error: 'no_target' });
    actor.blockedUserIds.add(targetUserId);
    ack && ack({ ok: true });
  });

  socket.on('unblock:user', (targetUserId, ack) => {
    const userId = socketIdToUserId.get(socket.id);
    if (!userId) return ack && ack({ ok: false, error: 'not_registered' });
    const actor = usersById.get(userId);
    actor.blockedUserIds.delete(targetUserId);
    ack && ack({ ok: true });
  });

  socket.on('private:message', (msg, ack) => {
    const fromUserId = socketIdToUserId.get(socket.id);
    if (!fromUserId) return ack && ack({ ok: false, error: 'not_registered' });

    const toUserId = String(msg && msg.toUserId || '');
    const text = String(msg && msg.text || '').slice(0, 2000);

    if (!usersById.has(toUserId)) return ack && ack({ ok: false, error: 'target_offline' });

    const fromUser = usersById.get(fromUserId);
    const target = usersById.get(toUserId);

    // Respect blocks: if target blocked sender, drop silently
    if (target.blockedUserIds.has(fromUserId)) {
      return ack && ack({ ok: false, error: 'blocked_by_user' });
    }

    const payload = {
      id: nanoid(8),
      fromUserId,
      toUserId,
      text,
      ts: Date.now(),
    };

    // Emit to sender (echo) and receiver
    io.to(fromUser.socketId).emit('private:message', payload);
    if (target && target.socketId) io.to(target.socketId).emit('private:message', payload);

    ack && ack({ ok: true, message: payload });
  });

  socket.on('private:typing', ({ toUserId, isTyping }) => {
    const fromUserId = socketIdToUserId.get(socket.id);
    if (!fromUserId || !usersById.has(toUserId)) return;
    const target = usersById.get(toUserId);
    if (target.blockedUserIds.has(fromUserId)) return; // respect block
    io.to(target.socketId).emit('private:typing', { fromUserId, isTyping: !!isTyping });
  });

  socket.on('poke:user', (toUserId) => {
    const fromUserId = socketIdToUserId.get(socket.id);
    if (!fromUserId || !usersById.has(toUserId)) return;
    const target = usersById.get(toUserId);
    if (target.blockedUserIds.has(fromUserId)) return; // respect block
    io.to(target.socketId).emit('player:poked', { fromUserId, ts: Date.now() });
  });

  socket.on('disconnect', () => {
    const userId = socketIdToUserId.get(socket.id);
    if (!userId) return;
    const user = usersById.get(userId);
    if (!user) return;
    user.status = 'offline';
    user.socketId = '';
    user.lastSeen = Date.now();
    socketIdToUserId.delete(socket.id);
    io.emit('player:updated', publicUser(user));
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`Private Chat server listening on http://localhost:${PORT}`);
});
