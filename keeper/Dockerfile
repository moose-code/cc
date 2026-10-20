FROM node:22.19.0-slim
WORKDIR /app
COPY package.json package-lock.json ./
COPY keeper/package.json ./keeper/package.json
COPY packages/engine/package.json ./packages/engine/package.json
COPY web/package.json ./web/package.json
RUN npm ci --omit=dev --workspace keeper --workspace @cc/engine
COPY keeper/src ./keeper/src
COPY packages/engine/src ./packages/engine/src
COPY deployments/1.json ./deployments/1.json
# Images default to no-send; production arming is the owner's explicit DRY_RUN=0 setting.
ENV NODE_ENV=production DRY_RUN=1
CMD ["sh", "-c", "umask 077; if [ -n \"${KEYSTORE:-}\" ]; then chmod 600 \"$KEYSTORE\" \"$KEYSTORE_PASSWORD_FILE\" || exit; fi; exec npm start --workspace keeper"]
