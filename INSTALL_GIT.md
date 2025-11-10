# Installing Git on Windows

Since Git is not currently installed on your system, here are the steps to install it:

## Option 1: Install Git for Windows (Recommended)

1. **Download Git:**
   - Go to [https://git-scm.com/download/win](https://git-scm.com/download/win)
   - The download will start automatically
   - Or download the latest version from the official site

2. **Run the Installer:**
   - Double-click the downloaded `.exe` file
   - Follow the installation wizard
   - **Recommended settings:**
     - Use Git from the command line and also from 3rd-party software
     - Use the OpenSSL library
     - Checkout Windows-style, commit Unix-style line endings
     - Use MinTTY (the default terminal of MSYS2)
     - Enable file system caching

3. **Verify Installation:**
   - Open a new PowerShell or Command Prompt window
   - Run: `git --version`
   - You should see something like: `git version 2.x.x`

4. **Configure Git (First Time):**
   ```bash
   git config --global user.name "Your Name"
   git config --global user.email "your.email@example.com"
   ```

## Option 2: Install via Package Manager

### Using Chocolatey (if installed):
```powershell
choco install git
```

### Using Winget (Windows 10/11):
```powershell
winget install --id Git.Git -e --source winget
```

### Using Scoop (if installed):
```powershell
scoop install git
```

## Option 3: Use GitHub Desktop (GUI Alternative)

If you prefer a graphical interface:

1. Download GitHub Desktop from [https://desktop.github.com/](https://desktop.github.com/)
2. Install and sign in with your GitHub account
3. Use the GUI to create repositories and push code

## After Installation

Once Git is installed, you can proceed with the GitHub setup:

1. Open a new PowerShell window (important - restart to get updated PATH)
2. Navigate to your project:
   ```powershell
   cd D:\projects\android_studio\kotak_neo_order
   ```
3. Follow the steps in `GITHUB_SETUP.md` or the README.md

## Troubleshooting

### Git command still not found after installation:
- **Restart your terminal/PowerShell** - The PATH environment variable is updated during installation
- Close and reopen PowerShell/Command Prompt
- If still not working, restart your computer

### Check if Git is installed:
```powershell
where.exe git
```
This should show the path to git.exe if it's installed.

### Manual PATH addition (if needed):
1. Find where Git was installed (usually `C:\Program Files\Git\cmd`)
2. Add it to your system PATH:
   - Right-click "This PC" → Properties
   - Advanced system settings → Environment Variables
   - Edit "Path" under System variables
   - Add the Git bin directory

## Alternative: Upload via GitHub Web Interface

If you can't install Git right now, you can:

1. Create a repository on GitHub (via web interface)
2. Use GitHub's web interface to upload files:
   - Go to your repository
   - Click "uploading an existing file"
   - Drag and drop your project files
   - **IMPORTANT:** Make sure to exclude `b.txt` and other sensitive files

However, using Git is recommended for version control and easier updates.

