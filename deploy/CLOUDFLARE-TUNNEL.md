<div dir="rtl">

# نصب لومی با تونل Cloudflare

با این روش لومی روی یک زیردامنه مثل `loomi.example.com` در دسترس است، **بدون IP ثابت و بدون باز کردن پورت در مودم**. HTTPS را Cloudflare می‌دهد.

## ۱. ساخت VM
- Ubuntu Server 24.04، با ۲ تا ۴ هسته، ۴ تا ۸ گیگ رم و ۴۰ گیگ دیسک.
- فقط دسترسی اینترنت خروجی لازم است.

## ۲. نصب Docker روی VM
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # بعدش یک بار خارج و وارد شوید
```

## ۳. ساخت تونل در Cloudflare
1. وارد [dash.cloudflare.com](https://dash.cloudflare.com) شوید و از منوی کناری **Zero Trust** را باز کنید.
   - اولین بار یک اسم تیم و پلن **Free** می‌خواهد. ممکن است Cloudflare برای فعال کردن پلن رایگان، اطلاعات پرداخت هم بخواهد.
2. به **Networks ← Tunnels** بروید و **Create a tunnel** را بزنید.
3. نوع **Cloudflared** را انتخاب کنید، یک اسم مثل `loomi` بدهید و ذخیره کنید.
4. در صفحه‌ی نصب، محیط **Docker** را انتخاب کنید. در دستوری که نشان می‌دهد، رشته‌ی طولانی بعد از `--token` را کپی کنید. **این توکن را جایی منتشر نکنید.**
5. **Next** را بزنید و در بخش **Public Hostname**:
   - **Subdomain:** `loomi`
   - **Domain:** `example.com`
   - **Service:** نوع `HTTP`، آدرس `server:8787`
6. **Save tunnel** را بزنید. Cloudflare رکورد DNS را خودش می‌سازد.

## ۴. اجرای لومی
```bash
git clone <مخزن لومی> loomi && cd loomi/deploy
cp .env.example .env
nano .env
```
در فایل `.env` این‌ها را پر کنید:
- `LOOMI_DOMAIN=loomi.example.com`
- `POSTGRES_PASSWORD=` خروجی دستور `openssl rand -hex 24`
- `LOOMI_MASTER_KEY=` خروجی دستور `openssl rand -hex 32`
  - **یک نسخه‌ی امن از این کلید نگه دارید.** بدون آن، کلیدهای API ذخیره‌شده قابل خواندن نیستند.
- `CLOUDFLARE_TUNNEL_TOKEN=` توکن مرحله‌ی ۳

بعد اجرا کنید:
```bash
docker compose -f docker-compose.tunnel.yml up -d
docker compose -f docker-compose.tunnel.yml logs server   # QR و کد جفت‌سازی اولین دستگاه
```

## ۵. بررسی
- در مرورگر باز کنید: `https://loomi.example.com/v1/health`. باید `{"ok":true,"name":"loomi",…}` ببینید.
- در Cloudflare، وضعیت تونل باید **Healthy** باشد.
- در اپ لومی، QR را اسکن کنید، یا آدرس `loomi.example.com` و کد ۸ رقمی را وارد کنید.

## نکته‌ها
- **دستگاه بعدی:** از داخل اپ «دستگاه تازه» را بزنید، یا روی سرور اجرا کنید:
  ```bash
  docker compose -f docker-compose.tunnel.yml exec server node dist/cli.js pair
  ```
- **به‌روزرسانی:**
  ```bash
  git pull && docker compose -f docker-compose.tunnel.yml up -d --build
  ```
- **رمزنگاری:** در این روش، رمزنگاری HTTPS روی Cloudflare باز می‌شود. اگر نمی‌خواهید Cloudflare ترافیک را ببیند، از روش پراکسی روی IP ثابت (`docker-compose.yml` و Caddy) استفاده کنید.

</div>
