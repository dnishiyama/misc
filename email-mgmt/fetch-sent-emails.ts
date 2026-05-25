import axios from "axios";
import * as dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";

dotenv.config();

const GOOGLE_REFRESH_TOKEN = process.env.GOOGLE_REFRESH_TOKEN;
const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET;

const OUTPUT_DIR = "sent-emails";

interface GmailMessage {
  id: string;
  threadId: string;
  payload: {
    headers: Array<{ name: string; value: string }>;
    body?: { data?: string };
    parts?: Array<{
      mimeType: string;
      body?: { data?: string };
      parts?: Array<{
        mimeType: string;
        body?: { data?: string };
      }>;
    }>;
  };
  snippet: string;
}

interface EmailData {
  id: string;
  threadId: string;
  subject: string;
  to: string;
  from: string;
  date: string;
  body: string;
}

async function getAccessToken(): Promise<string> {
  console.log("getAccessToken", { starting: true });

  if (!GOOGLE_REFRESH_TOKEN || !GOOGLE_CLIENT_ID || !GOOGLE_CLIENT_SECRET) {
    throw new Error(
      "Missing required environment variables: GOOGLE_REFRESH_TOKEN, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET"
    );
  }

  const response = await axios.post<{ access_token: string }>(
    "https://oauth2.googleapis.com/token",
    new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      refresh_token: GOOGLE_REFRESH_TOKEN,
      grant_type: "refresh_token",
    }),
    {
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
    }
  );

  return response.data.access_token;
}

async function fetchSentEmails(
  accessToken: string,
  maxResults: number
): Promise<EmailData[]> {
  console.log("fetchSentEmails", { maxResults });

  const listResponse = await axios.get<{
    messages?: Array<{ id: string; threadId: string }>;
  }>(
    `https://gmail.googleapis.com/gmail/v1/users/me/messages?labelIds=SENT&maxResults=${maxResults}`,
    {
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    }
  );

  const messages = listResponse.data.messages ?? [];
  console.log("fetchSentEmails", { messagesCount: messages.length });

  const emails: EmailData[] = [];

  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i];
    if (!msg) continue;

    try {
      const msgResponse = await axios.get<GmailMessage>(
        `https://gmail.googleapis.com/gmail/v1/users/me/messages/${msg.id}?format=full`,
        {
          headers: {
            Authorization: `Bearer ${accessToken}`,
          },
        }
      );

      const email = parseEmail(msgResponse.data);
      if (email) {
        emails.push(email);
        console.log(`Fetched email ${i + 1}/${messages.length}: ${email.subject.substring(0, 50)}`);
      }
    } catch (err) {
      console.warn(`Error fetching message ${msg.id}:`, err);
    }
  }

  return emails;
}

function parseEmail(msgData: GmailMessage): EmailData | null {
  const headers = msgData.payload.headers;

  const getHeader = (name: string): string => {
    const header = headers.find(
      (h) => h.name.toLowerCase() === name.toLowerCase()
    );
    return header?.value ?? "";
  };

  const subject = getHeader("Subject");
  const to = getHeader("To");
  const from = getHeader("From");
  const date = getHeader("Date");

  let body = "";

  const extractText = (
    parts:
      | Array<{
          mimeType: string;
          body?: { data?: string };
          parts?: Array<{ mimeType: string; body?: { data?: string } }>;
        }>
      | undefined
  ): string => {
    if (!parts) return "";

    for (const part of parts) {
      if (part.mimeType === "text/plain" && part.body?.data) {
        return Buffer.from(part.body.data, "base64").toString("utf-8");
      }
      if (part.parts) {
        const text = extractText(part.parts);
        if (text) return text;
      }
    }
    return "";
  };

  if (msgData.payload.body?.data) {
    body = Buffer.from(msgData.payload.body.data, "base64").toString("utf-8");
  } else if (msgData.payload.parts) {
    body = extractText(msgData.payload.parts);
  }

  // Skip emails with no meaningful content
  if (!body || body.trim().length < 20) {
    return null;
  }

  return {
    id: msgData.id,
    threadId: msgData.threadId,
    subject,
    to,
    from,
    date,
    body: cleanEmailBody(body),
  };
}

function cleanEmailBody(body: string): string {
  const lines = body.split("\n");

  const replyMarkers = [
    "On ",
    "From:",
    "---------- Forwarded message",
    "-------- Original Message",
    "> ",
  ];

  const cleanedLines: string[] = [];
  for (const line of lines) {
    if (replyMarkers.some((marker) => line.trim().startsWith(marker))) {
      if (
        line.includes("wrote:") ||
        line.startsWith(">") ||
        line.includes("Original Message")
      ) {
        break;
      }
    }
    cleanedLines.push(line);
  }

  return cleanedLines.join("\n").trim();
}

function sanitizeFilename(str: string): string {
  return str
    .replace(/[^a-zA-Z0-9-_\s]/g, "")
    .replace(/\s+/g, "-")
    .substring(0, 50)
    .toLowerCase();
}

function saveEmailAsMarkdown(email: EmailData, index: number): void {
  const filename = `${String(index).padStart(3, "0")}-${sanitizeFilename(email.subject || "no-subject")}.md`;
  const filepath = path.join(OUTPUT_DIR, filename);

  const content = `---
id: ${email.id}
threadId: ${email.threadId}
subject: ${email.subject}
to: ${email.to}
from: ${email.from}
date: ${email.date}
---

${email.body}
`;

  fs.writeFileSync(filepath, content, "utf-8");
}

async function main() {
  console.log("main", { starting: true });

  try {
    // Create output directory
    if (!fs.existsSync(OUTPUT_DIR)) {
      fs.mkdirSync(OUTPUT_DIR, { recursive: true });
    }

    // Get access token
    console.log("Getting access token...");
    const accessToken = await getAccessToken();
    console.log("Access token obtained successfully");

    // Fetch sent emails
    console.log("Fetching sent emails...");
    const emails = await fetchSentEmails(accessToken, 150);
    console.log(`Fetched ${emails.length} emails total`);

    if (emails.length === 0) {
      console.error("No emails found. Check your Gmail permissions.");
      process.exit(1);
    }

    // Save each email as markdown
    console.log(`Saving emails to ${OUTPUT_DIR}/...`);
    for (let i = 0; i < emails.length; i++) {
      const email = emails[i];
      if (!email) continue;
      saveEmailAsMarkdown(email, i + 1);
    }

    console.log(`Done! Saved ${emails.length} emails to ${OUTPUT_DIR}/`);
  } catch (error) {
    console.error("main error", { error });
    process.exit(1);
  }
}

main();





