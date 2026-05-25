import axios from "axios";
import * as dotenv from "dotenv";
import * as readline from "readline";

dotenv.config();

const GOOGLE_REFRESH_TOKEN = process.env.GOOGLE_REFRESH_TOKEN;
const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET;

interface Draft {
  id: string;
  message: {
    id: string;
    threadId: string;
  };
}

interface DraftDetails {
  id: string;
  subject: string;
  to: string;
  snippet: string;
  date: string;
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

async function fetchAllDrafts(accessToken: string): Promise<Draft[]> {
  console.log("fetchAllDrafts", { starting: true });

  const allDrafts: Draft[] = [];
  let pageToken: string | undefined;

  do {
    const url = pageToken
      ? `https://gmail.googleapis.com/gmail/v1/users/me/drafts?pageToken=${pageToken}`
      : "https://gmail.googleapis.com/gmail/v1/users/me/drafts";

    const response = await axios.get<{
      drafts?: Draft[];
      nextPageToken?: string;
    }>(url, {
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    });

    const drafts = response.data.drafts ?? [];
    allDrafts.push(...drafts);
    pageToken = response.data.nextPageToken;

    console.log("fetchAllDrafts", { fetchedSoFar: allDrafts.length, hasMore: !!pageToken });
  } while (pageToken);

  return allDrafts;
}

async function getDraftDetails(accessToken: string, draftId: string): Promise<DraftDetails> {
  const response = await axios.get<{
    id: string;
    message: {
      id: string;
      snippet: string;
      payload: {
        headers: Array<{ name: string; value: string }>;
      };
    };
  }>(`https://gmail.googleapis.com/gmail/v1/users/me/drafts/${draftId}`, {
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });

  const headers = response.data.message.payload.headers;

  const getHeader = (name: string): string => {
    const header = headers.find((h) => h.name.toLowerCase() === name.toLowerCase());
    return header?.value ?? "";
  };

  return {
    id: draftId,
    subject: getHeader("Subject") || "(No Subject)",
    to: getHeader("To") || "(No Recipient)",
    snippet: response.data.message.snippet,
    date: getHeader("Date") || "Unknown",
  };
}

async function deleteDraft(accessToken: string, draftId: string): Promise<void> {
  await axios.delete(`https://gmail.googleapis.com/gmail/v1/users/me/drafts/${draftId}`, {
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });
}

function askQuestion(question: string): Promise<string> {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim().toLowerCase());
    });
  });
}

async function main() {
  console.log("main", { starting: true });
  console.log("\n=== Gmail Draft Deletion Tool ===\n");

  try {
    // Get access token
    console.log("Authenticating...");
    const accessToken = await getAccessToken();
    console.log("Authenticated successfully\n");

    // Fetch all drafts
    console.log("Fetching drafts...");
    const drafts = await fetchAllDrafts(accessToken);

    if (drafts.length === 0) {
      console.log("\n✓ No drafts found. Your drafts folder is empty!");
      return;
    }

    console.log(`\nFound ${drafts.length} draft(s). Fetching details...\n`);

    // Get details for each draft
    const draftDetails: DraftDetails[] = [];
    for (let i = 0; i < drafts.length; i++) {
      const draft = drafts[i];
      if (!draft) continue;

      try {
        const details = await getDraftDetails(accessToken, draft.id);
        draftDetails.push(details);
      } catch (err) {
        console.warn(`Could not fetch details for draft ${draft.id}`);
      }
    }

    // Display all drafts
    console.log("=".repeat(80));
    console.log("DRAFTS TO DELETE:");
    console.log("=".repeat(80));

    for (let i = 0; i < draftDetails.length; i++) {
      const draft = draftDetails[i];
      if (!draft) continue;

      console.log(`\n[${i + 1}] Subject: ${draft.subject}`);
      console.log(`    To: ${draft.to}`);
      console.log(`    Date: ${draft.date}`);
      console.log(`    Preview: ${draft.snippet.substring(0, 100)}...`);
    }

    console.log("\n" + "=".repeat(80));
    console.log(`\nTotal: ${draftDetails.length} draft(s) will be PERMANENTLY DELETED.`);
    console.log("\n⚠️  WARNING: This action cannot be undone!\n");

    // Ask for confirmation
    const answer = await askQuestion("Type 'DELETE' to confirm deletion, or anything else to cancel: ");

    if (answer !== "delete") {
      console.log("\n✗ Cancelled. No drafts were deleted.");
      return;
    }

    // Delete all drafts
    console.log("\nDeleting drafts...\n");

    let deleted = 0;
    let failed = 0;

    for (let i = 0; i < draftDetails.length; i++) {
      const draft = draftDetails[i];
      if (!draft) continue;

      try {
        await deleteDraft(accessToken, draft.id);
        deleted++;
        console.log(`✓ Deleted [${i + 1}/${draftDetails.length}]: ${draft.subject}`);
      } catch (err) {
        failed++;
        console.error(`✗ Failed to delete: ${draft.subject}`);
      }
    }

    console.log("\n" + "=".repeat(80));
    console.log(`\nDone! Deleted ${deleted} draft(s).`);
    if (failed > 0) {
      console.log(`Failed to delete ${failed} draft(s).`);
    }
  } catch (error) {
    console.error("main error", { error });
    process.exit(1);
  }
}

main();





