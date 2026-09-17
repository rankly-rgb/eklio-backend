update public.site_platforms
   set status = 'refused',
       notice = 'We do not publish to Squarespace. Its API covers store orders and forms, not website pages, so there is no way for us to put anything on your site for you. Everything we write for you would still be yours to paste, but putting it in place is the part we could not do.'
 where id = 'squarespace';
