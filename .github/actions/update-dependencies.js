// .github/scripts/update-dependencies.js
const fs = require('fs');
const path = require('path');
const glob = require('glob');
const { Octokit } = require('@octokit/rest');

// Initialize GitHub client
const octokit = new Octokit({
  auth: process.env.GITHUB_TOKEN
});

// Function to extract action repo info from uses string
function extractRepoInfo(usesString) {
  // Handle different formats of the 'uses' field
  if (usesString.startsWith('./') || usesString.startsWith('../')) {
    // Local action, skip
    return null;
  }

  // Handle Docker image actions
  if (usesString.startsWith('docker://')) {
    // Docker action, skip
    return null;
  }

  // Parse GitHub action reference
  const parts = usesString.split('@');
  if (parts.length !== 2) {
    return null;
  }

  const repoPath = parts[0];
  const version = parts[1];

  // Skip if already using a commit SHA
  if (version.match(/^[0-9a-f]{40}$/)) {
    return null;
  }

  // Extract owner and repo
  const repoPathParts = repoPath.split('/');
  if (repoPathParts.length !== 2) {
    return null;
  }

  return {
    owner: repoPathParts[0],
    repo: repoPathParts[1],
    currentVersion: version
  };
}

// Function to get the latest stable tag and its commit SHA
async function getLatestStableTag(owner, repo) {
  try {
    // Get all tags
    const { data: tags } = await octokit.repos.listTags({
      owner,
      repo,
      per_page: 100
    });

    // Filter for stable version tags (vX.Y.Z format)
    const stableTags = tags.filter(tag => {
      const name = tag.name;
      // Match common version formats like v1.2.3, 1.2.3, v1.2, etc.
      return /^v?\d+(\.\d+)*$/.test(name);
    });

    if (stableTags.length === 0) {
      // If no stable tags found, use the latest tag
      return tags.length > 0 ? tags[0] : null;
    }

    // Sort by semver (this is a simple implementation and might need refinement)
    stableTags.sort((a, b) => {
      const aVersion = a.name.replace(/^v/, '').split('.').map(Number);
      const bVersion = b.name.replace(/^v/, '').split('.').map(Number);
      
      for (let i = 0; i < Math.max(aVersion.length, bVersion.length); i++) {
        const aNum = i < aVersion.length ? aVersion[i] : 0;
        const bNum = i < bVersion.length ? bVersion[i] : 0;
        if (aNum !== bNum) {
          return bNum - aNum; // Descending order
        }
      }
      return 0;
    });

    return stableTags[0];
  } catch (error) {
    console.error(`Error fetching tags for ${owner}/${repo}:`, error);
    return null;
  }
}

// Function to update action references in workflow files
async function updateWorkflowFiles() {
  const workflowFiles = glob.sync('.github/workflows/**/*.{yml,yaml}');
  const changes = [];

  for (const file of workflowFiles) {
    let content = fs.readFileSync(file, 'utf8');
    let modified = false;
    
    // Find all 'uses:' lines
    const usesRegex = /^\s*uses:\s*([^#\n]+)/gm;
    let match;
    
    while ((match = usesRegex.exec(content)) !== null) {
      const fullMatch = match[0];
      const usesString = match[1].trim();
      
      const repoInfo = extractRepoInfo(usesString);
      if (!repoInfo) {
        continue;
      }
      
      const { owner, repo, currentVersion } = repoInfo;
      
      // Get latest stable tag
      const latestTag = await getLatestStableTag(owner, repo);
      if (!latestTag) {
        console.log(`⚠️ No tags found for ${owner}/${repo}`);
        continue;
      }
      
      // Get the commit SHA
      const commitSha = latestTag.commit.sha;
      
      // Create the new uses string
      const newUsesString = `uses: ${owner}/${repo}@${commitSha}`;
      
      // Replace in content
      const newFullMatch = fullMatch.replace(usesString, `${owner}/${repo}@${commitSha}`);
      content = content.replace(fullMatch, newFullMatch);
      modified = true;
      
      changes.push(`* Updated \`${owner}/${repo}\` from \`${currentVersion}\` to \`${latestTag.name}\` (SHA: \`${commitSha}\`)`);
      console.log(`✅ Updated ${owner}/${repo} to ${latestTag.name} (${commitSha})`);
    }
    
    if (modified) {
      fs.writeFileSync(file, content);
    }
  }
  
  // Also look for action.yml files within the repository that might reference other actions
  const actionFiles = glob.sync('**/action.{yml,yaml}');
  
  for (const file of actionFiles) {
    let content = fs.readFileSync(file, 'utf8');
    let modified = false;
    
    // Find all 'uses:' lines
    const usesRegex = /^\s*uses:\s*([^#\n]+)/gm;
    let match;
    
    while ((match = usesRegex.exec(content)) !== null) {
      const fullMatch = match[0];
      const usesString = match[1].trim();
      
      const repoInfo = extractRepoInfo(usesString);
      if (!repoInfo) {
        continue;
      }
      
      const { owner, repo, currentVersion } = repoInfo;
      
      // Get latest stable tag
      const latestTag = await getLatestStableTag(owner, repo);
      if (!latestTag) {
        console.log(`⚠️ No tags found for ${owner}/${repo}`);
        continue;
      }
      
      // Get the commit SHA
      const commitSha = latestTag.commit.sha;
      
      // Create the new uses string
      const newUsesString = `uses: ${owner}/${repo}@${commitSha}`;
      
      // Replace in content
      const newFullMatch = fullMatch.replace(usesString, `${owner}/${repo}@${commitSha}`);
      content = content.replace(fullMatch, newFullMatch);
      modified = true;
      
      changes.push(`* Updated \`${owner}/${repo}\` from \`${currentVersion}\` to \`${latestTag.name}\` (SHA: \`${commitSha}\`)`);
      console.log(`✅ Updated ${owner}/${repo} to ${latestTag.name} (${commitSha})`);
    }
    
    if (modified) {
      fs.writeFileSync(file, content);
    }
  }

  // Set output for the GitHub Action
  if (changes.length > 0) {
    const changesOutput = changes.join('\n');
    // Set output for GitHub Actions
    console.log(`::set-output name=changes::${changesOutput}`);
    // For newer GitHub Actions
    fs.appendFileSync(process.env.GITHUB_OUTPUT || '', `changes<<EOF\n${changesOutput}\nEOF\n`);
    return true;
  }
  
  return false;
}

// Main function
async function main() {
  try {
    const hasChanges = await updateWorkflowFiles();
    if (!hasChanges) {
      console.log('No updates needed. All actions are already using the latest stable versions.');
    }
  } catch (error) {
    console.error('Error updating dependencies:', error);
    process.exit(1);
  }
}

main();
