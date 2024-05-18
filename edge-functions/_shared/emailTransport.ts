import nodemailer from 'npm:nodemailer@6.9.10'

const Transport = nodemailer.createTransport({
    host: Deno.env.get('NODEMAILER_HOST')!,
    port: Number(Deno.env.get('NODEMAILER_PORT')!),
    secure: Boolean(Deno.env.get('NODEMAILER_SECURE')!),
    auth: {
        user: Deno.env.get('NODEMAILER_EMAIL')!,
        pass: Deno.env.get('NODEMAILER_PASSWORD')!
    }
});

export default Transport;
