const socket = io();

const playersEl = document.getElementById('players');
const searchInput = document.getElementById('searchInput');
const statusFilter = document.getElementById('statusFilter');
const nameInput = document.getElementById('nameInput');
const saveNameBtn = document.getElementById('saveName');
const myStatus = document.getElementById('myStatus');

const beginChatBtn = document.getElementById('beginChat');
const blockBtn = document.getElementById('blockBtn');
const pokeBtn = document.getElementById('pokeBtn');
const doNotDisturb = document.getElementById('doNotDisturb');

const chatWith = document.getElementById('chatWith');
const messagesEl = document.getElementById('messages');
const messageInput = document.getElementById('messageInput');
const sendBtn = document.getElementById('sendBtn');
const peerPresence = document.getElementById('peerPresence');

let me = null; // { userId, name, status }
let players = []; // public players list
let selectedUserId = null;
const unreadByUser = new Map();

// Local identity persistence
const stored = JSON.parse(localStorage.getItem('pc_identity') || 'null');
if (stored && stored.userId) {
  nameInput.value = stored.name || '';
}

function register() {
  return new Promise((resolve) => {
    socket.emit('register', { userId: stored && stored.userId, name: nameInput.value.trim() || 'Misafir' }, (res) => {
      if (res && res.ok) {
        me = res.user;
        localStorage.setItem('pc_identity', JSON.stringify(me));
        updateMyControls();
        resolve();
      }
    });
  });
}

function updateMyControls() {
  if (!me) return;
  nameInput.value = me.name;
  myStatus.value = me.status === 'dnd' ? 'dnd' : 'online';
}

function renderPlayers() {
  const q = searchInput.value.trim().toLowerCase();
  const f = statusFilter.value;

  playersEl.innerHTML = '';
  players
    .filter((p) => (f === 'all' ? true : p.status === f))
    .filter((p) => p.userId !== (me && me.userId))
    .filter((p) => p.name.toLowerCase().includes(q))
    .sort((a, b) => {
      const order = { online: 0, dnd: 1, offline: 2 };
      const s = order[a.status] - order[b.status];
      if (s !== 0) return s;
      return a.name.localeCompare(b.name);
    })
    .forEach((p) => {
      const row = document.createElement('div');
      row.className = 'player' + (selectedUserId === p.userId ? ' selected' : '');
      row.dataset.userId = p.userId;

      const dot = document.createElement('span');
      dot.className = 'status-dot status-' + (p.status || 'offline');

      const name = document.createElement('div');
      name.className = 'name';
      name.textContent = p.name;

      const unread = document.createElement('span');
      const count = unreadByUser.get(p.userId) || 0;
      if (count > 0) {
        unread.className = 'unread';
        unread.textContent = count;
      }

      row.appendChild(dot);
      row.appendChild(name);
      if (count > 0) row.appendChild(unread);

      row.addEventListener('click', () => selectUser(p.userId));
      playersEl.appendChild(row);
    });

  const hasSel = !!selectedUserId;
  beginChatBtn.disabled = !hasSel;
  blockBtn.disabled = !hasSel;
  pokeBtn.disabled = !hasSel;
}

function selectUser(userId) {
  selectedUserId = userId;
  unreadByUser.delete(userId);
  renderPlayers();
  const user = players.find((p) => p.userId === userId);
  chatWith.textContent = user ? user.name : 'Sohbet';
  peerPresence.textContent = user ? (user.status === 'online' ? 'Online' : user.status === 'dnd' ? 'Rahatsız Etmeyin' : 'Offline') : '';
  messagesEl.innerHTML = '';
}

function appendMessage({ text, fromUserId, ts }) {
  const div = document.createElement('div');
  const mine = fromUserId === (me && me.userId);
  div.className = 'message ' + (mine ? 'outgoing' : 'incoming');
  div.innerHTML = `<div class="body"></div><div class="meta"></div>`;
  div.querySelector('.body').textContent = text;
  const meta = new Date(ts || Date.now()).toLocaleTimeString();
  div.querySelector('.meta').textContent = meta;
  messagesEl.appendChild(div);
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

sendBtn.addEventListener('click', () => {
  const text = messageInput.value.trim();
  if (!text || !selectedUserId) return;
  socket.emit('private:message', { toUserId: selectedUserId, text }, (res) => {
    if (res && res.ok) {
      messageInput.value = '';
    }
  });
});

messageInput.addEventListener('input', () => {
  if (!selectedUserId) return;
  socket.emit('private:typing', { toUserId: selectedUserId, isTyping: messageInput.value.length > 0 });
});

saveNameBtn.addEventListener('click', async () => {
  await register();
});

myStatus.addEventListener('change', () => {
  const v = myStatus.value;
  socket.emit('set:status', v);
  me.status = v;
  localStorage.setItem('pc_identity', JSON.stringify(me));
  renderPlayers();
});

doNotDisturb.addEventListener('change', () => {
  const v = doNotDisturb.checked ? 'dnd' : 'online';
  myStatus.value = v;
  socket.emit('set:status', v);
  me.status = v;
  localStorage.setItem('pc_identity', JSON.stringify(me));
  renderPlayers();
});

beginChatBtn.addEventListener('click', () => {
  if (!selectedUserId) return;
  messageInput.focus();
});

blockBtn.addEventListener('click', () => {
  if (!selectedUserId) return;
  socket.emit('block:user', selectedUserId, (res) => {
    if (res && res.ok) alert('Kullanıcı engellendi.');
  });
});

pokeBtn.addEventListener('click', () => {
  if (!selectedUserId) return;
  socket.emit('poke:user', selectedUserId);
});

// Socket events
socket.on('connect', async () => {
  await register();
});

socket.on('players:list', (list) => {
  players = list;
  renderPlayers();
});

socket.on('player:updated', (u) => {
  const idx = players.findIndex((p) => p.userId === u.userId);
  if (idx >= 0) players[idx] = u; else players.push(u);
  renderPlayers();
});

socket.on('private:message', (msg) => {
  const isRelevant = (msg.fromUserId === (me && me.userId) && msg.toUserId === selectedUserId) ||
                     (msg.toUserId === (me && me.userId) && msg.fromUserId === selectedUserId);

  if (!isRelevant) {
    const otherId = msg.fromUserId === (me && me.userId) ? msg.toUserId : msg.fromUserId;
    unreadByUser.set(otherId, (unreadByUser.get(otherId) || 0) + 1);
    renderPlayers();
    return;
  }

  appendMessage(msg);
});

socket.on('private:typing', ({ fromUserId, isTyping }) => {
  if (fromUserId !== selectedUserId) return;
  peerPresence.textContent = isTyping ? 'Yazıyor…' : '';
});

socket.on('player:poked', ({ fromUserId }) => {
  if (fromUserId !== selectedUserId) return;
  peerPresence.textContent = 'Dürtüldü!';
  setTimeout(() => { peerPresence.textContent = ''; }, 1500);
});
