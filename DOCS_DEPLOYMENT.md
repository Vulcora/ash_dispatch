# Private Documentation Deployment

## Cloudflare Pages Setup (Free & Recommended)

### 1. Create Cloudflare Account
- Sign up at [cloudflare.com](https://cloudflare.com) (free tier)
- Go to **Workers & Pages** in the dashboard

### 2. Get API Credentials
- Go to **My Profile** → **API Tokens**
- Create token with **"Cloudflare Pages - Edit"** permissions
- Note your **Account ID** from the dashboard URL or Workers & Pages overview

### 3. Add GitHub Secrets
In your GitHub repo, go to **Settings** → **Secrets and variables** → **Actions**:
- `CLOUDFLARE_API_TOKEN`: Your API token from step 2
- `CLOUDFLARE_ACCOUNT_ID`: Your account ID from step 2

### 4. Configure Access Control
After first deployment:
1. Go to Cloudflare dashboard → **Workers & Pages**
2. Select your **ash-dispatch-docs** project
3. Go to **Settings** → **Access Policy**
4. Add policy to restrict by:
   - Email addresses (add team members)
   - Email domains (e.g., @yourcompany.com)
   - IP addresses

### 5. Deploy
Push to main branch - docs will auto-deploy to:
`https://ash-dispatch-docs.pages.dev`

---

## Alternative: Vercel (Also Free)

If you prefer Vercel:

1. Install Vercel CLI: `npm i -g vercel`
2. In repo root: `vercel link`
3. Add to workflow:
   ```yaml
   - name: Deploy to Vercel
     run: vercel --prod --token=${{ secrets.VERCEL_TOKEN }}
   ```
4. Restrict access in Vercel dashboard → Project Settings → Password Protection

---

## Alternative: Keep in Repo (Simplest)

If you just want team access without hosting:

1. Keep docs in `doc/` folder
2. Team members view via GitHub's web interface
3. Or run `mix docs && open doc/index.html` locally

**Pros**: No setup needed
**Cons**: Less convenient than web hosting
