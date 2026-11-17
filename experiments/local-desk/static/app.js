const chat = document.querySelector("#chat");
const composer = document.querySelector("#composer");

const state = {
  topic: null,
  verificationId: null,
  mode: "words",
};

function addMessage(role, text) {
  const item = document.createElement("p");
  item.className = `msg ${role}`;
  item.textContent = text;
  chat.appendChild(item);
  chat.scrollTop = chat.scrollHeight;
}

function setComposer(mode, html) {
  state.mode = mode;
  composer.innerHTML = html;
}

function showWords() {
  state.topic = null;
  state.verificationId = null;
  setComposer(
    "words",
    `<label>Kata-kata customer<textarea name="text" required></textarea></label>
     <button type="submit">Kirim</button>`
  );
}

function showVerifyForm() {
  setComposer(
    "verify",
    `<label>Username<input name="username" autocomplete="off" required></label>
     <label>Jawaban verifikasi<input name="answer" autocomplete="off" required></label>
     <button type="submit">Verifikasi</button>`
  );
}

function showPasswordForm() {
  setComposer(
    "password",
    `<label>Password baru<input name="newPassword" type="password" minlength="8" autocomplete="new-password" required></label>
     <button type="submit">Ubah password</button>`
  );
}

async function postJson(url, body) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const result = await response.json();
  if (!response.ok && !result.message) {
    throw new Error("Permintaan gagal.");
  }
  return result;
}

composer.addEventListener("submit", async (event) => {
  event.preventDefault();
  const submit = composer.querySelector("button[type='submit']");
  if (submit) submit.disabled = true;
  const data = new FormData(composer);

  try {
    if (state.mode === "words") {
      const text = String(data.get("text") || "").trim();
      addMessage("user", text);
      const result = await postJson("/api/understand", { text });
      addMessage("bot", result.message);
      if (!result.topic) {
        showWords();
        return;
      }
      state.topic = result.topic;
      showVerifyForm();
      return;
    }

    if (state.mode === "verify") {
      const username = String(data.get("username") || "").trim();
      const answer = String(data.get("answer") || "").trim();
      addMessage("user", `Verifikasi untuk ${username}`);
      const result = await postJson("/api/verify", {
        username,
        answer,
        topic: state.topic,
      });
      addMessage("bot", result.message);
      if (!result.ok || state.topic === "withdrawal_issue") {
        showWords();
        return;
      }
      state.verificationId = result.verificationId;
      showPasswordForm();
      return;
    }

    if (state.mode === "password") {
      addMessage("user", "Password baru dikirim.");
      const result = await postJson("/api/change-password", {
        verificationId: state.verificationId,
        newPassword: String(data.get("newPassword") || ""),
      });
      addMessage("bot", result.message);
      showWords();
    }
  } catch (error) {
    addMessage("bot", "Meja CS tidak bisa membaca pesan itu. Password tidak diubah.");
    showWords();
  }
});

addMessage(
  "bot",
  "Tulis kata-kata customer apa adanya. Basa-basi, kalimat yang belum jelas, atau permintaan langsung semuanya bisa dikirim."
);
showWords();
