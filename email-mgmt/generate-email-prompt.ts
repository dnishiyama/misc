import * as fs from "fs";
import * as path from "path";

const EMAILS_DIR = "sent-emails";
const OUTPUT_FILE = "email-style-prompt.md";

interface EmailData {
  id: string;
  subject: string;
  to: string;
  from: string;
  date: string;
  body: string;
  filename: string;
}

function parseMarkdownEmail(filepath: string): EmailData | null {
  const content = fs.readFileSync(filepath, "utf-8");
  const filename = path.basename(filepath);

  // Parse frontmatter
  const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!frontmatterMatch) {
    console.warn(`parseMarkdownEmail: No frontmatter found in ${filename}`);
    return null;
  }

  const frontmatter = frontmatterMatch[1] ?? "";
  const body = (frontmatterMatch[2] ?? "").trim();

  const getValue = (key: string): string => {
    const match = frontmatter.match(new RegExp(`^${key}:\\s*(.*)$`, "m"));
    return match?.[1]?.trim() ?? "";
  };

  return {
    id: getValue("id"),
    subject: getValue("subject"),
    to: getValue("to"),
    from: getValue("from"),
    date: getValue("date"),
    body,
    filename,
  };
}

function loadAllEmails(): EmailData[] {
  console.log("loadAllEmails", { dir: EMAILS_DIR });

  if (!fs.existsSync(EMAILS_DIR)) {
    throw new Error(`Emails directory not found: ${EMAILS_DIR}. Run fetch-sent-emails.ts first.`);
  }

  const files = fs.readdirSync(EMAILS_DIR).filter((f) => f.endsWith(".md"));
  console.log("loadAllEmails", { filesCount: files.length });

  const emails: EmailData[] = [];

  for (const file of files) {
    const filepath = path.join(EMAILS_DIR, file);
    const email = parseMarkdownEmail(filepath);
    if (email && email.body.length > 0) {
      emails.push(email);
    }
  }

  return emails;
}

function analyzeWritingStyle(emails: EmailData[]): {
  greetings: Map<string, number>;
  signoffs: Map<string, number>;
  avgLength: number;
  toneIndicators: string[];
} {
  console.log("analyzeWritingStyle", { emailCount: emails.length });

  const greetings = new Map<string, number>();
  const signoffs = new Map<string, number>();
  let totalLength = 0;
  const toneIndicators: string[] = [];

  const greetingPatterns = [
    /^(hi|hey|hello|dear|good morning|good afternoon|good evening)[,!\s]*/im,
  ];

  const signoffPatterns = [
    /(best|thanks|thank you|cheers|regards|sincerely|warm regards|best regards|talk soon|take care)[\s,!]*$/im,
  ];

  for (const email of emails) {
    const body = email.body;
    totalLength += body.length;

    // Extract greeting
    const firstLine = body.split("\n")[0] ?? "";
    for (const pattern of greetingPatterns) {
      const match = firstLine.match(pattern);
      if (match) {
        const greeting = match[0].trim().toLowerCase();
        greetings.set(greeting, (greetings.get(greeting) ?? 0) + 1);
      }
    }

    // Extract signoff
    const lastLines = body.split("\n").slice(-5).join("\n");
    for (const pattern of signoffPatterns) {
      const match = lastLines.match(pattern);
      if (match) {
        const signoff = match[0].trim().toLowerCase();
        signoffs.set(signoff, (signoffs.get(signoff) ?? 0) + 1);
      }
    }

    // Detect tone indicators
    if (body.includes("!")) toneIndicators.push("uses_exclamations");
    if (body.match(/:\)|😊|😄|🙂/)) toneIndicators.push("uses_emoticons");
    if (body.length < 100) toneIndicators.push("tends_brief");
    if (body.length > 500) toneIndicators.push("tends_detailed");
  }

  return {
    greetings,
    signoffs,
    avgLength: emails.length > 0 ? Math.round(totalLength / emails.length) : 0,
    toneIndicators: [...new Set(toneIndicators)],
  };
}

function selectBestExamples(emails: EmailData[], count: number = 10): EmailData[] {
  // Filter for good examples
  const goodEmails = emails.filter((email) => {
    const bodyLength = email.body.length;
    return bodyLength > 50 && bodyLength < 2000 && email.subject.length > 0;
  });

  // Sort by length (prefer medium-length emails)
  const sorted = goodEmails.sort((a, b) => {
    const idealLength = 350;
    const aDiff = Math.abs(a.body.length - idealLength);
    const bDiff = Math.abs(b.body.length - idealLength);
    return aDiff - bDiff;
  });

  // Take a diverse sample
  const selected: EmailData[] = [];
  const usedSubjectWords = new Set<string>();

  for (const email of sorted) {
    if (selected.length >= count) break;

    const subjectWords = email.subject.toLowerCase().split(/\s+/);
    const isNovel = subjectWords.some((word) => !usedSubjectWords.has(word));

    if (isNovel || selected.length < 3) {
      selected.push(email);
      subjectWords.forEach((word) => usedSubjectWords.add(word));
    }
  }

  return selected;
}

function generatePromptFile(
  emails: EmailData[],
  style: ReturnType<typeof analyzeWritingStyle>
): string {
  const examples = selectBestExamples(emails, 10);

  const sortedGreetings = [...style.greetings.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5);
  const sortedSignoffs = [...style.signoffs.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5);

  let prompt = `# Email Writing Style Guide

This document contains examples and guidelines for writing emails that match my personal style.

## Writing Style Overview

### Tone & Voice
`;

  if (style.toneIndicators.includes("uses_exclamations")) {
    prompt += `- Uses exclamation marks for emphasis and warmth\n`;
  }
  if (style.toneIndicators.includes("uses_emoticons")) {
    prompt += `- Occasionally uses emoticons/emojis\n`;
  }
  if (style.toneIndicators.includes("tends_brief")) {
    prompt += `- Tends toward brief, concise messages\n`;
  }
  if (style.toneIndicators.includes("tends_detailed")) {
    prompt += `- Provides detailed, thorough responses\n`;
  }

  prompt += `- Average email length: ~${style.avgLength} characters\n\n`;

  prompt += `### Common Greetings\n`;
  if (sortedGreetings.length > 0) {
    for (const [greeting, count] of sortedGreetings) {
      prompt += `- "${greeting}" (used ${count} times)\n`;
    }
  } else {
    prompt += `- No consistent greeting pattern detected\n`;
  }

  prompt += `\n### Common Sign-offs\n`;
  if (sortedSignoffs.length > 0) {
    for (const [signoff, count] of sortedSignoffs) {
      prompt += `- "${signoff}" (used ${count} times)\n`;
    }
  } else {
    prompt += `- No consistent sign-off pattern detected\n`;
  }

  prompt += `\n## Key Writing Guidelines

1. **Keep it concise**: Get to the point quickly while remaining friendly
2. **Be direct**: State requests or information clearly upfront
3. **Match formality**: Adjust tone based on recipient relationship
4. **Use natural language**: Write conversationally, not robotically

## Example Emails

Below are real examples of emails I've sent. Use these as reference for tone, structure, and style.

`;

  for (let i = 0; i < examples.length; i++) {
    const email = examples[i];
    if (!email) continue;

    prompt += `### Example ${i + 1}
**Subject:** ${email.subject}
**To:** ${email.to}

\`\`\`
${email.body}
\`\`\`

---

`;
  }

  prompt += `## Instructions for Drafting Emails

When drafting an email on my behalf:

1. **Read the incoming email carefully** - Understand the context and what's being asked
2. **Match my typical greeting style** - Use greetings from the list above
3. **Keep the same level of formality** as the incoming email
4. **Be helpful and clear** - Address all questions/points raised
5. **Use my typical sign-off** - Choose from the sign-offs above
6. **Keep it appropriately brief** - Match my typical email length unless more detail is needed
7. **Sound natural** - The email should sound like a real person wrote it, not AI

### Response Format

When generating a draft response, provide:
1. A subject line (if needed)
2. The email body
3. Any notes about tone adjustments or alternatives
`;

  return prompt;
}

function main() {
  console.log("main", { starting: true });

  try {
    // Load all emails from markdown files
    const emails = loadAllEmails();
    console.log(`Loaded ${emails.length} emails`);

    if (emails.length === 0) {
      console.error("No emails found. Run fetch-sent-emails.ts first.");
      process.exit(1);
    }

    // Analyze writing style
    console.log("Analyzing writing style...");
    const style = analyzeWritingStyle(emails);
    console.log("analyzeWritingStyle result", {
      greetingsCount: style.greetings.size,
      signoffsCount: style.signoffs.size,
      avgLength: style.avgLength,
      toneIndicators: style.toneIndicators,
    });

    // Generate prompt file
    console.log("Generating prompt file...");
    const promptContent = generatePromptFile(emails, style);

    // Write to file
    fs.writeFileSync(OUTPUT_FILE, promptContent, "utf-8");
    console.log(`Prompt file written to: ${OUTPUT_FILE}`);
  } catch (error) {
    console.error("main error", { error });
    process.exit(1);
  }
}

main();





