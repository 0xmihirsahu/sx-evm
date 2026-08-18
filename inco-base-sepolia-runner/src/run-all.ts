import { spawn } from "node:child_process";

const scripts = [
  "src/base-sepolia-smoke.ts",
  "src/multi-voter.ts",
  "src/negative-cases.ts",
  "src/strategy-statuses.ts",
];

async function main(): Promise<void> {
  for (const script of scripts) {
    console.log(`\n=== Running ${script} ===`);
    await run("tsx", [script]);
  }
}

function run(command: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit", shell: true });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${command} ${args.join(" ")} exited with ${code}`));
      }
    });
  });
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
