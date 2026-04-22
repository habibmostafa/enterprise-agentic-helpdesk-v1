"use strict";

exports.handler = async (event) => {
  return {
    statusCode: 200,
    headers: { "Content-Type": "text/html" },
    body: HTML_PAGE,
  };
};

const HTML_PAGE = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Enterprise Helpdesk</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f0f2f5; height: 100vh; display: flex; flex-direction: column; }
header { background: #232f3e; color: white; padding: 16px 24px; display: flex; align-items: center; gap: 12px; }
header h1 { font-size: 18px; font-weight: 600; }
header .badge { background: #ff9900; color: #232f3e; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; }
#chat { flex: 1; overflow-y: auto; padding: 24px; display: flex; flex-direction: column; gap: 12px; }
.msg { max-width: 75%; padding: 12px 16px; border-radius: 12px; font-size: 14px; line-height: 1.5; word-wrap: break-word; }
.msg.user { align-self: flex-end; background: #0073bb; color: white; border-bottom-right-radius: 4px; }
.msg.bot { align-self: flex-start; background: white; color: #1a1a1a; border-bottom-left-radius: 4px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
.msg.bot .thinking { color: #666; font-style: italic; font-size: 12px; display: block; margin-bottom: 6px; }
.msg.system { align-self: center; background: #e8f4fd; color: #0073bb; font-size: 12px; border-radius: 8px; }
#input-area { padding: 16px 24px; background: white; border-top: 1px solid #e0e0e0; display: flex; gap: 12px; }
#input-area input { flex: 1; padding: 12px 16px; border: 1px solid #d0d0d0; border-radius: 8px; font-size: 14px; outline: none; }
#input-area input:focus { border-color: #0073bb; box-shadow: 0 0 0 2px rgba(0,115,187,0.2); }
#input-area button { padding: 12px 24px; background: #ff9900; color: #232f3e; border: none; border-radius: 8px; font-size: 14px; font-weight: 600; cursor: pointer; }
#input-area button:hover { background: #ec7211; }
#input-area button:disabled { opacity: 0.5; cursor: not-allowed; }
.typing { display: none; align-self: flex-start; padding: 12px 16px; background: white; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
.typing.active { display: flex; gap: 4px; }
.typing span { width: 8px; height: 8px; background: #999; border-radius: 50%; animation: bounce 1.4s infinite; }
.typing span:nth-child(2) { animation-delay: 0.2s; }
.typing span:nth-child(3) { animation-delay: 0.4s; }
@keyframes bounce { 0%,80%,100% { transform: translateY(0); } 40% { transform: translateY(-6px); } }
</style>
</head>
<body>
<header>
  <svg width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M12 2a10 10 0 0110 10c0 5.52-4.48 10-10 10a9.96 9.96 0 01-4.9-1.28L2 22l1.28-5.1A9.96 9.96 0 012 12 10 10 0 0112 2z"/></svg>
  <h1>Enterprise IT Helpdesk</h1>
  <span class="badge">AI-POWERED</span>
</header>

<div id="chat">
  <div class="msg system">Connected to AI Helpdesk. Ask me to create, check, or update IT tickets.</div>
</div>

<div class="typing" id="typing"><span></span><span></span><span></span></div>

<div id="input-area">
  <input type="text" id="input" placeholder="Describe your IT issue..." autocomplete="off" />
  <button id="send">Send</button>
</div>

<script>
const chatEl = document.getElementById('chat');
const inputEl = document.getElementById('input');
const sendBtn = document.getElementById('send');
const typingEl = document.getElementById('typing');

let sessionAttributes = {};
const API_URL = window.location.origin + '/chat';

function addMsg(text, role) {
  const div = document.createElement('div');
  div.className = 'msg ' + role;
  // Strip <thinking> tags for display
  const cleaned = text.replace(/<thinking>[\\s\\S]*?<\\/thinking>\\s*/g, '');
  div.innerHTML = cleaned.replace(/\\n/g, '<br>');
  chatEl.appendChild(div);
  chatEl.scrollTop = chatEl.scrollHeight;
}

function addSystemNotice(text) {
  const div = document.createElement('div');
  div.className = 'msg system';
  div.textContent = text;
  chatEl.appendChild(div);
  chatEl.scrollTop = chatEl.scrollHeight;
}

async function send() {
  const text = inputEl.value.trim();
  if (!text) return;
  
  addMsg(text, 'user');
  inputEl.value = '';
  sendBtn.disabled = true;
  typingEl.classList.add('active');
  chatEl.appendChild(typingEl);
  chatEl.scrollTop = chatEl.scrollHeight;

  try {
    const res = await fetch(API_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        inputTranscript: text,
        sessionState: {
          sessionAttributes: sessionAttributes,
          intent: { name: 'HelpDeskIntent' }
        }
      })
    });
    const data = await res.json();
    
    // Update session for multi-turn
    if (data.sessionState?.sessionAttributes) {
      sessionAttributes = data.sessionState.sessionAttributes;
      if (sessionAttributes._escalated === 'true') {
        addSystemNotice('Escalation created: A human IT agent has been requested for this conversation.');
      }
    }
    
    const reply = data.messages?.[0]?.content || 'No response received.';
    typingEl.classList.remove('active');
    addMsg(reply, 'bot');
  } catch (err) {
    typingEl.classList.remove('active');
    addMsg('Error: ' + err.message, 'system');
  }
  sendBtn.disabled = false;
  inputEl.focus();
}

sendBtn.addEventListener('click', send);
inputEl.addEventListener('keydown', (e) => { if (e.key === 'Enter') send(); });
inputEl.focus();
</script>
</body>
</html>`;

