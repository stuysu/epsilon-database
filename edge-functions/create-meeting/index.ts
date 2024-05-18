import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import corsHeaders from '../_shared/cors.ts';
import Transport from '../_shared/emailTransport.ts';

import { datetime } from "https://deno.land/x/ptera/mod.ts";

type BodyType = {
    organization_id: number,
    title: string,
    description: string,
    room_id?: number | null,
    start_time: string,
    end_time: string,
    is_public: boolean
}

const returnSelect = `
            id,
            is_public,
            title,
            description,
            start_time,
            end_time,
            rooms (
                id,
                name,
                floor
            )
        `;

Deno.serve(async (req : Request) => {
    if (req.method === 'OPTIONS') {
        return new Response('ok', { headers: corsHeaders })
    }

    const authHeader = req.headers.get('Authorization')!
    const supabaseClient = createClient(
        Deno.env.get('SUPABASE_URL') ?? '',
        Deno.env.get('SUPABASE_ANON_KEY') ?? '',
        { global: { headers: { Authorization: authHeader } } }
    );

    const jwt = authHeader.split(" ")[1];
    const { data: userData } = await supabaseClient.auth.getUser(jwt);
    const user = userData.user;

    /* Failed to fetch supabase user */
    if (!user) {
        return new Response("Failed to fetch user.", { status: 500 });
    }

    /* check if user is a verified user. Verified user = the userdata that the site uses */
    const { data: verifiedUsers, error: verifiedUsersError } = await supabaseClient.from('users')
        .select('*')
        .eq('email', user.email);
    
    if (verifiedUsersError) {
        return new Response("Failed to fetch users associated email.", { status: 500 });
    }

    if (!verifiedUsers || !verifiedUsers.length) {
        return new Response("User is unauthorized.", { status: 401 });
    }

    const siteUser = verifiedUsers[0];
    const bodyJson = await req.json();
    const body : BodyType = {
        organization_id: bodyJson.organization_id,
        title: bodyJson.title,
        description: bodyJson.description,
        room_id: bodyJson.room_id,
        start_time: bodyJson.start_time,
        end_time: bodyJson.end_time,
        is_public: bodyJson.is_public
    }

    /* validate that user is admin in organization */
    const { data: adminMembership, error: adminMembershipError } = await supabaseClient.from('memberships')
        .select(`id`)
        .eq('organization_id', body.organization_id)
        .eq('user_id', siteUser.id)
        .in('role', ['ADMIN', 'CREATOR']);
    
    if (adminMembershipError || !adminMembership || !adminMembership.length) {
        return new Response("User is unauthorized.", { status: 401 });
    }

    type rtyp = {
        id: number,
        is_public: boolean,
        title: string,
        description: string,
        start_time: string,
        end_time: string,
        rooms: {
            id: number,
            name: string,
            floor: number
        }
    }
    const { data: createMeetingData, error: createMeetingError } = await supabaseClient.from('meetings')
        .insert(body)
        .select(returnSelect)
        .returns<rtyp[]>();
    
    if (createMeetingError || !createMeetingData || !createMeetingData.length) {
        return new Response("Could not create meeting.", { status: 500 });
    }

    /* asynchronously email all members of organization */
    type mtyp = {
        users: {
            first_name: string,
            email: string,
            is_faculty: boolean
        },
        organizations: { name: string }
    };
    supabaseClient.from("memberships")
        .select(`
            users!inner (
                first_name,
                email,
                is_faculty
            ),
            organizations!inner (
                name
            )
        `)
        .eq('organization_id', body.organization_id)
        .returns<mtyp[]>()
        .then(resp => {
            const { data: memberData, error: memberError } = resp;
            if (memberError || !memberData || !memberData.length) {
                console.log("Error fetching members.");
                return;
            }

            const recipientEmails = [];
            const orgName = memberData[0].organizations.name

            for (const member of memberData) {
                // do not notify faculty
                if (member.users.is_faculty && !bodyJson.notify_faculty) continue;

                recipientEmails.push(member.users.email);
            }

            const startTime = datetime(createMeetingData[0].start_time).toZonedTime("America/New_York").format("MMMM, YYYY, h:mm a");
            const endTime = datetime(createMeetingData[0].end_time).toZonedTime("America/New_York").format("MMMM, YYYY, h:mm a");

            const emailText = `You are receiving this email because you are a member of ${orgName}
This email is to let you know of an upcoming meeting. The details of which are below.
Title: ${body.title}
Description: ${body.description}
Start Date: ${startTime} EST
End Date: ${endTime} EST
Room: ${createMeetingData[0].rooms?.name || "Virtual"}`

            try {
                // don't use await here. let this operation perform asynchronously 
                Transport.sendMail({
                    from: Deno.env.get('NODEMAILER_FROM')!,
                    bcc: recipientEmails,
                    subject: `${orgName} scheduled a meeting | Epsilon`,
                    text: emailText,
                })
            } catch (error) {
                console.log(error);
            }
        })

    return new Response(
        JSON.stringify({
            ...createMeetingData[0]
        }),
        {
            headers: { 'Content-Type': 'application/json' },
        }
    );
})
