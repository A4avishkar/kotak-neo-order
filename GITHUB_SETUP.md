# GitHub Setup Guide

This guide will help you publish your Kotak Neo Order project to GitHub.

## Prerequisites

- Git installed on your system
- GitHub account
- Project files ready (credentials excluded)

## Step-by-Step Instructions

### 1. Verify Your .gitignore File

Before proceeding, make sure your `.gitignore` file excludes sensitive files:
- `b.txt` (contains credentials)
- `android/local.properties` (may contain sensitive paths)
- Build artifacts and temporary files

### 2. Check for Sensitive Files

Run this command to verify sensitive files are not tracked:
```bash
git status
```

You should **NOT** see:
- `b.txt`
- `android/local.properties`
- Any files containing your credentials

### 3. Create a GitHub Repository

1. Go to [GitHub.com](https://github.com)
2. Click the "+" icon in the top right corner
3. Select "New repository"
4. Fill in the repository details:
   - **Name:** `kotak-neo-order` (or your preferred name)
   - **Description:** "Flutter mobile app and Python CLI for Kotak Neo order placement"
   - **Visibility:** Public or Private (your choice)
   - **DO NOT** check "Initialize this repository with a README" (we already have one)
5. Click "Create repository"

### 4. Initialize Git (if not already done)

If you haven't initialized git yet:
```bash
git init
```

### 5. Add Files to Git

```bash
# Add all files (respecting .gitignore)
git add .

# Verify what will be committed
git status
```

**IMPORTANT:** Double-check that `b.txt` is NOT in the list of files to be committed!

### 6. Create Your First Commit

```bash
git commit -m "Initial commit: Kotak Neo Order Flutter app and Python CLI"
```

### 7. Connect to GitHub

Replace `YOUR_USERNAME` and `YOUR_REPO_NAME` with your actual values:
```bash
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO_NAME.git
```

For example:
```bash
git remote add origin https://github.com/johndoe/kotak-neo-order.git
```

### 8. Push to GitHub

```bash
# Set the default branch to main
git branch -M main

# Push your code to GitHub
git push -u origin main
```

You may be prompted for your GitHub username and password (or personal access token).

### 9. Verify on GitHub

1. Go to your repository on GitHub
2. Verify all files are present
3. Verify `b.txt` is **NOT** visible
4. Check that the README displays correctly

## Security Checklist

Before pushing to GitHub, verify:

- [ ] `b.txt` is NOT in git status
- [ ] `android/local.properties` is NOT in git status
- [ ] `.gitignore` includes `b.txt`
- [ ] `.gitignore` includes `android/local.properties`
- [ ] No hardcoded credentials in source code
- [ ] `b.txt.example` exists as a template (without real credentials)

## If You Accidentally Committed Sensitive Files

If you accidentally committed `b.txt` or other sensitive files:

1. **Remove from Git (but keep local file):**
   ```bash
   git rm --cached b.txt
   ```

2. **Add to .gitignore (if not already there):**
   ```bash
   echo "b.txt" >> .gitignore
   ```

3. **Commit the removal:**
   ```bash
   git add .gitignore
   git commit -m "Remove sensitive files from version control"
   ```

4. **If already pushed to GitHub:**
   - The file will still be in history
   - Consider using `git filter-branch` or BFG Repo-Cleaner to remove from history
   - **Change your credentials immediately** if they were exposed

## Updating the Repository

After making changes:

```bash
# Check what changed
git status

# Add changes
git add .

# Commit changes
git commit -m "Description of your changes"

# Push to GitHub
git push
```

## Making Releases

To create a release on GitHub:

1. Go to your repository on GitHub
2. Click "Releases" → "Create a new release"
3. Tag version (e.g., `v1.0.0`)
4. Add release notes
5. Upload APK/IPA files if desired
6. Publish release

## Troubleshooting

### Git is not recognized
- Install Git from [git-scm.com](https://git-scm.com/)
- Or use GitHub Desktop application

### Authentication failed
- Use a Personal Access Token instead of password
- Generate token: GitHub Settings → Developer settings → Personal access tokens

### Push rejected
- Make sure you have write access to the repository
- Check if the repository exists and the URL is correct

## Next Steps

After publishing to GitHub:

1. Add a license file (if desired)
2. Set up GitHub Actions for CI/CD (optional)
3. Add issue templates (optional)
4. Create a CONTRIBUTING.md file (optional)
5. Share the repository link with others!

