import { deploy, sponsor } from './lib/snapshot-inco.js';

async function main(): Promise<void> {
  console.log('Deployer:', sponsor.address);
  const factory = await deploy(
    'ProxyFactory',
    'out/ProxyFactory.sol/ProxyFactory.json'
  );
  console.log('---');
  console.log('ProxyFactory deployed at:', factory.address);
  console.log('Paste this into packages/sx.js/src/evmNetworks.ts under basesep.proxyFactory');
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
