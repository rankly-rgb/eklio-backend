// ─────────────────────────────────────────────────────────────────────────────
// GENERATED FROM THE DATABASE. Do not hand-edit.
//
// Produced by the Supabase CLI against a clean replay of supabase/migrations
// plus supabase/seed.sql, which is this repository's source of truth:
//
//   supabase gen types typescript --db-url "$DB_URL" > types/supabase.ts
//
// ⚠ The point of this file is that it is NOT a guess. A hand-written type and a
// test written from the same hand-written type agree with each other and pass
// while both are wrong — which is how `p_stripe_event_id` survived. Import
// `Database` here and every invented column or RPC parameter fails at compile
// time, with a file and a name, instead of on the payment path in production.
// ─────────────────────────────────────────────────────────────────────────────

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  public: {
    Tables: {
      app_settings: {
        Row: {
          key: string
          value: NonNullable<Json>
        }
        Insert: {
          key: string
          value: NonNullable<Json>
        }
        Update: {
          key?: string
          value?: NonNullable<Json>
        }
        Relationships: []
      }
      banned_phrases: {
        Row: {
          active: boolean
          category: string
          id: string
          phrase: string
        }
        Insert: {
          active?: boolean
          category: string
          id?: string
          phrase: string
        }
        Update: {
          active?: boolean
          category?: string
          id?: string
          phrase?: string
        }
        Relationships: []
      }
      brand_kits: {
        Row: {
          content: NonNullable<Json>
          created_at: string
          direction_id: string | null
          directions: Json | null
          ethics_check: Json | null
          id: string
          multi_builder_prompt: string | null
          origin: string
          pdf_url: string | null
          practitioner_line: string | null
          project_id: string
          selected_direction_id: string | null
          share_slug: string | null
          site_prompt: string | null
          site_prompt_target: string | null
          social_templates: Json | null
          tier: string
          updated_at: string
          voice_guide: Json | null
        }
        Insert: {
          content?: NonNullable<Json>
          created_at?: string
          direction_id?: string | null
          directions?: Json | null
          ethics_check?: Json | null
          id?: string
          multi_builder_prompt?: string | null
          origin?: string
          pdf_url?: string | null
          practitioner_line?: string | null
          project_id: string
          selected_direction_id?: string | null
          share_slug?: string | null
          site_prompt?: string | null
          site_prompt_target?: string | null
          social_templates?: Json | null
          tier?: string
          updated_at?: string
          voice_guide?: Json | null
        }
        Update: {
          content?: NonNullable<Json>
          created_at?: string
          direction_id?: string | null
          directions?: Json | null
          ethics_check?: Json | null
          id?: string
          multi_builder_prompt?: string | null
          origin?: string
          pdf_url?: string | null
          practitioner_line?: string | null
          project_id?: string
          selected_direction_id?: string | null
          share_slug?: string | null
          site_prompt?: string | null
          site_prompt_target?: string | null
          social_templates?: Json | null
          tier?: string
          updated_at?: string
          voice_guide?: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "brand_kits_direction_id_fkey"
            columns: ["direction_id"]
            isOneToOne: false
            referencedRelation: "directions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "brand_kits_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: true
            referencedRelation: "projects"
            referencedColumns: ["id"]
          },
        ]
      }
      builder_targets: {
        Row: {
          accepts_prompt: boolean | null
          active: boolean
          color_panel: string | null
          docs_url: string | null
          font_panel: string | null
          id: string
          label: string
          output_kind: string
          section_panel: string | null
          sort_order: number
          template_hint: string | null
        }
        Insert: {
          accepts_prompt?: never
          active?: boolean
          color_panel?: string | null
          docs_url?: string | null
          font_panel?: string | null
          id: string
          label: string
          output_kind: string
          section_panel?: string | null
          sort_order: number
          template_hint?: string | null
        }
        Update: {
          accepts_prompt?: never
          active?: boolean
          color_panel?: string | null
          docs_url?: string | null
          font_panel?: string | null
          id?: string
          label?: string
          output_kind?: string
          section_panel?: string | null
          sort_order?: number
          template_hint?: string | null
        }
        Relationships: []
      }
      client_persona_cards: {
        Row: {
          active: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          description?: string
          id?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      comp_grants: {
        Row: {
          created_at: string
          expires_at: string
          generation_credits: number
          granted_by: string
          id: string
          reason: string
          revoked_at: string | null
          user_id: string
        }
        Insert: {
          created_at?: string
          expires_at: string
          generation_credits?: number
          granted_by: string
          id?: string
          reason: string
          revoked_at?: string | null
          user_id: string
        }
        Update: {
          created_at?: string
          expires_at?: string
          generation_credits?: number
          granted_by?: string
          id?: string
          reason?: string
          revoked_at?: string | null
          user_id?: string
        }
        Relationships: []
      }
      direction_asset_daily_spend: {
        Row: {
          actual_cents: number
          reserved_cents: number
          spend_date: string
        }
        Insert: {
          actual_cents?: number
          reserved_cents?: number
          spend_date?: string
        }
        Update: {
          actual_cents?: number
          reserved_cents?: number
          spend_date?: string
        }
        Relationships: []
      }
      direction_assets: {
        Row: {
          brand_kit_id: string
          claimed_at: string | null
          cost_cents: number | null
          created_at: string
          direction_index: number
          id: string
          kind: string
          palette_hash: string | null
          reserved_cents: number | null
          status: string
          storage_path: string | null
          updated_at: string
          url: string | null
        }
        Insert: {
          brand_kit_id: string
          claimed_at?: string | null
          cost_cents?: number | null
          created_at?: string
          direction_index: number
          id?: string
          kind?: string
          palette_hash?: string | null
          reserved_cents?: number | null
          status?: string
          storage_path?: string | null
          updated_at?: string
          url?: string | null
        }
        Update: {
          brand_kit_id?: string
          claimed_at?: string | null
          cost_cents?: number | null
          created_at?: string
          direction_index?: number
          id?: string
          kind?: string
          palette_hash?: string | null
          reserved_cents?: number | null
          status?: string
          storage_path?: string | null
          updated_at?: string
          url?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "direction_assets_brand_kit_id_fkey"
            columns: ["brand_kit_id"]
            isOneToOne: false
            referencedRelation: "brand_kits"
            referencedColumns: ["id"]
          },
        ]
      }
      directions: {
        Row: {
          body_font: string
          created_at: string
          description: string
          heading_font: string
          id: string
          is_selected: boolean
          name: string
          palette: NonNullable<Json>
          position: number
          project_id: string
          updated_at: string
        }
        Insert: {
          body_font: string
          created_at?: string
          description: string
          heading_font: string
          id?: string
          is_selected?: boolean
          name: string
          palette: NonNullable<Json>
          position: number
          project_id: string
          updated_at?: string
        }
        Update: {
          body_font?: string
          created_at?: string
          description?: string
          heading_font?: string
          id?: string
          is_selected?: boolean
          name?: string
          palette?: NonNullable<Json>
          position?: number
          project_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "directions_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "projects"
            referencedColumns: ["id"]
          },
        ]
      }
      ethics_rules: {
        Row: {
          active: boolean
          description: string
          example_forbidden: string
          id: string
          short_label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          description: string
          example_forbidden: string
          id: string
          short_label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          description?: string
          example_forbidden?: string
          id?: string
          short_label?: string
          sort_order?: number
        }
        Relationships: []
      }
      gain_cards: {
        Row: {
          active: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          description?: string
          id?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      generation_credits: {
        Row: {
          created_at: string
          directions_generated: number
          has_paid: boolean
          id: string
          plan_tier: string
          project_id: string
          regenerations_used: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          directions_generated?: number
          has_paid?: boolean
          id?: string
          plan_tier?: string
          project_id: string
          regenerations_used?: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          directions_generated?: number
          has_paid?: boolean
          id?: string
          plan_tier?: string
          project_id?: string
          regenerations_used?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "generation_credits_plan_tier_fkey"
            columns: ["plan_tier"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["tier"]
          },
          {
            foreignKeyName: "generation_credits_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: true
            referencedRelation: "projects"
            referencedColumns: ["id"]
          },
        ]
      }
      launch_checklist_items: {
        Row: {
          brand_kit_id: string
          created_at: string
          description: string | null
          done_at: string | null
          id: string
          key: string
          label: string
          sort_order: number
          updated_at: string
          user_id: string
        }
        Insert: {
          brand_kit_id: string
          created_at?: string
          description?: string | null
          done_at?: string | null
          id?: string
          key: string
          label: string
          sort_order: number
          updated_at?: string
          user_id: string
        }
        Update: {
          brand_kit_id?: string
          created_at?: string
          description?: string | null
          done_at?: string | null
          id?: string
          key?: string
          label?: string
          sort_order?: number
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "launch_checklist_items_brand_kit_id_fkey"
            columns: ["brand_kit_id"]
            isOneToOne: false
            referencedRelation: "brand_kits"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "launch_checklist_items_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      license_types: {
        Row: {
          active: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          description?: string
          id?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      modality_cards: {
        Row: {
          active: boolean
          full_name: string
          id: string
          label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          full_name: string
          id: string
          label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          full_name?: string
          id?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      modality_prominence_options: {
        Row: {
          active: boolean
          id: string
          label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          id: string
          label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          id?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      monthly_presence_content: {
        Row: {
          brand_kit_id: string
          caption: string | null
          created_at: string
          day_of_month: number
          id: string
          month: string
          published_at: string | null
          status: string
          title: string | null
          type: string
          updated_at: string
          user_id: string
          visual_spec: Json | null
        }
        Insert: {
          brand_kit_id: string
          caption?: string | null
          created_at?: string
          day_of_month: number
          id?: string
          month: string
          published_at?: string | null
          status?: string
          title?: string | null
          type: string
          updated_at?: string
          user_id: string
          visual_spec?: Json | null
        }
        Update: {
          brand_kit_id?: string
          caption?: string | null
          created_at?: string
          day_of_month?: number
          id?: string
          month?: string
          published_at?: string | null
          status?: string
          title?: string | null
          type?: string
          updated_at?: string
          user_id?: string
          visual_spec?: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "monthly_presence_content_brand_kit_id_fkey"
            columns: ["brand_kit_id"]
            isOneToOne: false
            referencedRelation: "brand_kits"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "monthly_presence_content_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      not_a_fit_cards: {
        Row: {
          active: boolean
          id: string
          label: string
          referral_note: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          id: string
          label: string
          referral_note: string
          sort_order: number
        }
        Update: {
          active?: boolean
          id?: string
          label?: string
          referral_note?: string
          sort_order?: number
        }
        Relationships: []
      }
      organization_members: {
        Row: {
          activated_at: string | null
          created_at: string
          id: string
          invite_token_hash: string | null
          invited_email: string | null
          organization_id: string
          project_id: string | null
          removed_at: string | null
          role: string
          status: string
          user_id: string | null
        }
        Insert: {
          activated_at?: string | null
          created_at?: string
          id?: string
          invite_token_hash?: string | null
          invited_email?: string | null
          organization_id: string
          project_id?: string | null
          removed_at?: string | null
          role: string
          status: string
          user_id?: string | null
        }
        Update: {
          activated_at?: string | null
          created_at?: string
          id?: string
          invite_token_hash?: string | null
          invited_email?: string | null
          organization_id?: string
          project_id?: string | null
          removed_at?: string | null
          role?: string
          status?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "organization_members_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_members_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "projects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_members_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          brand_charter_kit_id: string | null
          created_at: string
          id: string
          name: string
          owner_user_id: string
          slug: string
        }
        Insert: {
          brand_charter_kit_id?: string | null
          created_at?: string
          id?: string
          name: string
          owner_user_id: string
          slug: string
        }
        Update: {
          brand_charter_kit_id?: string | null
          created_at?: string
          id?: string
          name?: string
          owner_user_id?: string
          slug?: string
        }
        Relationships: [
          {
            foreignKeyName: "organizations_brand_charter_kit_id_fkey"
            columns: ["brand_charter_kit_id"]
            isOneToOne: false
            referencedRelation: "brand_kits"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organizations_owner_user_id_fkey"
            columns: ["owner_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      palette_families: {
        Row: {
          accent_hex: string
          accent_text_hex: string
          active: boolean
          cta_ink_hex: string
          dark_hex: string
          id: string
          label: string
          light_hex: string
          paper_hex: string
          preview_tokens: NonNullable<Json>
          primary_hex: string
          primary_text_hex: string
          secondary_hex: string
          secondary_text_hex: string
          sort_order: number
          swatches: string[]
        }
        Insert: {
          accent_hex?: string
          accent_text_hex?: string
          active?: boolean
          cta_ink_hex?: string
          dark_hex: string
          id: string
          label: string
          light_hex: string
          paper_hex: string
          preview_tokens: NonNullable<Json>
          primary_hex: string
          primary_text_hex?: string
          secondary_hex: string
          secondary_text_hex?: string
          sort_order: number
          swatches: string[]
        }
        Update: {
          accent_hex?: string
          accent_text_hex?: string
          active?: boolean
          cta_ink_hex?: string
          dark_hex?: string
          id?: string
          label?: string
          light_hex?: string
          paper_hex?: string
          preview_tokens?: NonNullable<Json>
          primary_hex?: string
          primary_text_hex?: string
          secondary_hex?: string
          secondary_text_hex?: string
          sort_order?: number
          swatches?: string[]
        }
        Relationships: []
      }
      plan_grants: {
        Row: {
          grant_key: string
          granted_at: string
          id: string
          project_id: string
          tier: string
        }
        Insert: {
          grant_key: string
          granted_at?: string
          id?: string
          project_id: string
          tier: string
        }
        Update: {
          grant_key?: string
          granted_at?: string
          id?: string
          project_id?: string
          tier?: string
        }
        Relationships: [
          {
            foreignKeyName: "plan_grants_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "projects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_grants_tier_fkey"
            columns: ["tier"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["tier"]
          },
        ]
      }
      plans: {
        Row: {
          created_at: string
          directions_limit: number
          label: string
          price_cents: number
          regenerations_limit: number
          sort_order: number
          tier: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          directions_limit: number
          label: string
          price_cents: number
          regenerations_limit: number
          sort_order: number
          tier: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          directions_limit?: number
          label?: string
          price_cents?: number
          regenerations_limit?: number
          sort_order?: number
          tier?: string
          updated_at?: string
        }
        Relationships: []
      }
      primary_actions: {
        Row: {
          active: boolean
          id: string
          label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          id: string
          label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          id?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      problem_cards: {
        Row: {
          active: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          description?: string
          id?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      profiles: {
        Row: {
          created_at: string
          email: string
          full_name: string | null
          id: string
          stripe_customer_id: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          email: string
          full_name?: string | null
          id: string
          stripe_customer_id?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          email?: string
          full_name?: string | null
          id?: string
          stripe_customer_id?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      project_briefs: {
        Row: {
          builder_target_id: string | null
          city: string | null
          client_persona_ids: string[]
          completed_steps: number[]
          data: NonNullable<Json>
          gain_card_ids: string[]
          license_type_id: string | null
          modality_ids: string[] | null
          modality_prominence: string | null
          not_a_fit_ids: string[] | null
          not_a_fit_text: string | null
          palette_family_ids: string[]
          positioning: string | null
          practice_name: string | null
          primary_action_id: string | null
          prior_career: string | null
          prior_career_public: boolean
          problem_card_ids: string[]
          progress_step: number
          project_id: string
          referral_quote: string | null
          selected_usp_id: string | null
          session_style_ids: string[] | null
          site_goal_ids: string[]
          specialty_ids: string[]
          state: string | null
          tone_card_id: string | null
          tone_cards: Json | null
          tone_cards_inputs_hash: string | null
          type_pairing_id: string | null
          updated_at: string
          usp_options: Json | null
          usp_statement: string | null
        }
        Insert: {
          builder_target_id?: string | null
          city?: string | null
          client_persona_ids?: string[]
          completed_steps?: number[]
          data?: NonNullable<Json>
          gain_card_ids?: string[]
          license_type_id?: string | null
          modality_ids?: string[] | null
          modality_prominence?: string | null
          not_a_fit_ids?: string[] | null
          not_a_fit_text?: string | null
          palette_family_ids?: string[]
          positioning?: string | null
          practice_name?: string | null
          primary_action_id?: string | null
          prior_career?: string | null
          prior_career_public?: boolean
          problem_card_ids?: string[]
          progress_step?: number
          project_id: string
          referral_quote?: string | null
          selected_usp_id?: string | null
          session_style_ids?: string[] | null
          site_goal_ids?: string[]
          specialty_ids?: string[]
          state?: string | null
          tone_card_id?: string | null
          tone_cards?: Json | null
          tone_cards_inputs_hash?: string | null
          type_pairing_id?: string | null
          updated_at?: string
          usp_options?: Json | null
          usp_statement?: string | null
        }
        Update: {
          builder_target_id?: string | null
          city?: string | null
          client_persona_ids?: string[]
          completed_steps?: number[]
          data?: NonNullable<Json>
          gain_card_ids?: string[]
          license_type_id?: string | null
          modality_ids?: string[] | null
          modality_prominence?: string | null
          not_a_fit_ids?: string[] | null
          not_a_fit_text?: string | null
          palette_family_ids?: string[]
          positioning?: string | null
          practice_name?: string | null
          primary_action_id?: string | null
          prior_career?: string | null
          prior_career_public?: boolean
          problem_card_ids?: string[]
          progress_step?: number
          project_id?: string
          referral_quote?: string | null
          selected_usp_id?: string | null
          session_style_ids?: string[] | null
          site_goal_ids?: string[]
          specialty_ids?: string[]
          state?: string | null
          tone_card_id?: string | null
          tone_cards?: Json | null
          tone_cards_inputs_hash?: string | null
          type_pairing_id?: string | null
          updated_at?: string
          usp_options?: Json | null
          usp_statement?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "project_briefs_builder_target_id_fkey"
            columns: ["builder_target_id"]
            isOneToOne: false
            referencedRelation: "builder_targets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "project_briefs_license_type_id_fkey"
            columns: ["license_type_id"]
            isOneToOne: false
            referencedRelation: "license_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "project_briefs_modality_prominence_fkey"
            columns: ["modality_prominence"]
            isOneToOne: false
            referencedRelation: "modality_prominence_options"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "project_briefs_primary_action_id_fkey"
            columns: ["primary_action_id"]
            isOneToOne: false
            referencedRelation: "primary_actions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "project_briefs_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: true
            referencedRelation: "projects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "project_briefs_tone_card_id_fkey"
            columns: ["tone_card_id"]
            isOneToOne: false
            referencedRelation: "tone_cards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "project_briefs_type_pairing_id_fkey"
            columns: ["type_pairing_id"]
            isOneToOne: false
            referencedRelation: "type_pairings"
            referencedColumns: ["id"]
          },
        ]
      }
      projects: {
        Row: {
          created_at: string
          current_step: number
          id: string
          name: string
          organization_id: string
          profession: string | null
          status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          current_step?: number
          id?: string
          name?: string
          organization_id: string
          profession?: string | null
          status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          current_step?: number
          id?: string
          name?: string
          organization_id?: string
          profession?: string | null
          status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "projects_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "projects_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_status_events: {
        Row: {
          amount_cents: number | null
          created_at: string
          event_type: string
          id: string
          new_status: string
          occurred_at: string
          previous_status: string | null
          purchase_id: string
          stripe_event_id: string
        }
        Insert: {
          amount_cents?: number | null
          created_at?: string
          event_type: string
          id?: string
          new_status: string
          occurred_at: string
          previous_status?: string | null
          purchase_id: string
          stripe_event_id: string
        }
        Update: {
          amount_cents?: number | null
          created_at?: string
          event_type?: string
          id?: string
          new_status?: string
          occurred_at?: string
          previous_status?: string | null
          purchase_id?: string
          stripe_event_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchase_status_events_purchase_id_fkey"
            columns: ["purchase_id"]
            isOneToOne: false
            referencedRelation: "purchases"
            referencedColumns: ["id"]
          },
        ]
      }
      purchases: {
        Row: {
          amount_cents: number
          created_at: string
          currency: string
          id: string
          organization_id: string | null
          paid_at: string | null
          project_id: string | null
          status: string
          stripe_checkout_session_id: string
          stripe_payment_intent_id: string | null
          tier: string
          updated_at: string
          user_id: string
        }
        Insert: {
          amount_cents: number
          created_at?: string
          currency?: string
          id?: string
          organization_id?: string | null
          paid_at?: string | null
          project_id?: string | null
          status?: string
          stripe_checkout_session_id: string
          stripe_payment_intent_id?: string | null
          tier: string
          updated_at?: string
          user_id: string
        }
        Update: {
          amount_cents?: number
          created_at?: string
          currency?: string
          id?: string
          organization_id?: string | null
          paid_at?: string | null
          project_id?: string | null
          status?: string
          stripe_checkout_session_id?: string
          stripe_payment_intent_id?: string | null
          tier?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchases_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "projects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      section_types: {
        Row: {
          active: boolean
          allowed_pages: string[]
          default_enabled: boolean
          description: string
          fields: NonNullable<Json>
          id: string
          label: string
          sort_order: number
          source: string
        }
        Insert: {
          active?: boolean
          allowed_pages: string[]
          default_enabled: boolean
          description: string
          fields: NonNullable<Json>
          id: string
          label: string
          sort_order: number
          source?: string
        }
        Update: {
          active?: boolean
          allowed_pages?: string[]
          default_enabled?: boolean
          description?: string
          fields?: NonNullable<Json>
          id?: string
          label?: string
          sort_order?: number
          source?: string
        }
        Relationships: []
      }
      session_style_cards: {
        Row: {
          active: boolean
          description: string
          id: string
          label: string
          sort_order: number
          voice_hints: string[]
        }
        Insert: {
          active?: boolean
          description: string
          id: string
          label: string
          sort_order: number
          voice_hints: string[]
        }
        Update: {
          active?: boolean
          description?: string
          id?: string
          label?: string
          sort_order?: number
          voice_hints?: string[]
        }
        Relationships: []
      }
      site_goals: {
        Row: {
          active: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          description: string
          id: string
          label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          description?: string
          id?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      site_output_templates: {
        Row: {
          active: boolean
          body: string
          id: string
          key: string
          sort_order: number
          target: string | null
        }
        Insert: {
          active?: boolean
          body: string
          id: string
          key: string
          sort_order?: number
          target?: string | null
        }
        Update: {
          active?: boolean
          body?: string
          id?: string
          key?: string
          sort_order?: number
          target?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "site_output_templates_target_fkey"
            columns: ["target"]
            isOneToOne: false
            referencedRelation: "builder_targets"
            referencedColumns: ["id"]
          },
        ]
      }
      site_specs: {
        Row: {
          about_excerpt: string
          accent_hex: string
          accent_text_hex: string
          body_font: string
          brand_kit_id: string
          change_marks: NonNullable<Json>
          created_at: string
          cta_ink_hex: string
          dark_neutral_hex: string
          extra_instructions: string | null
          field_sources: NonNullable<Json>
          font_display_fallback: string | null
          google_fonts_url: string
          heading_font: string
          hero: NonNullable<Json>
          id: string
          last_copied_spec_version: number | null
          light_neutral_hex: string
          logo_png_dark_path: string | null
          logo_png_light_path: string | null
          logo_svg_path: string | null
          monogram_svg_path: string | null
          pages: NonNullable<Json>
          paper_hex: string
          practice_details: NonNullable<Json>
          primary_hex: string
          primary_text_hex: string
          secondary_hex: string
          secondary_text_hex: string
          seed_clamped: Json | null
          spec_version: number
          target: string
          type_pairing_id: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          about_excerpt?: string
          accent_hex: string
          accent_text_hex: string
          body_font: string
          brand_kit_id: string
          change_marks?: NonNullable<Json>
          created_at?: string
          cta_ink_hex: string
          dark_neutral_hex: string
          extra_instructions?: string | null
          field_sources?: NonNullable<Json>
          font_display_fallback?: string | null
          google_fonts_url: string
          heading_font: string
          hero: NonNullable<Json>
          id?: string
          last_copied_spec_version?: number | null
          light_neutral_hex: string
          logo_png_dark_path?: string | null
          logo_png_light_path?: string | null
          logo_svg_path?: string | null
          monogram_svg_path?: string | null
          pages: NonNullable<Json>
          paper_hex: string
          practice_details?: NonNullable<Json>
          primary_hex: string
          primary_text_hex: string
          secondary_hex: string
          secondary_text_hex: string
          seed_clamped?: Json | null
          spec_version?: number
          target?: string
          type_pairing_id?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          about_excerpt?: string
          accent_hex?: string
          accent_text_hex?: string
          body_font?: string
          brand_kit_id?: string
          change_marks?: NonNullable<Json>
          created_at?: string
          cta_ink_hex?: string
          dark_neutral_hex?: string
          extra_instructions?: string | null
          field_sources?: NonNullable<Json>
          font_display_fallback?: string | null
          google_fonts_url?: string
          heading_font?: string
          hero?: NonNullable<Json>
          id?: string
          last_copied_spec_version?: number | null
          light_neutral_hex?: string
          logo_png_dark_path?: string | null
          logo_png_light_path?: string | null
          logo_svg_path?: string | null
          monogram_svg_path?: string | null
          pages?: NonNullable<Json>
          paper_hex?: string
          practice_details?: NonNullable<Json>
          primary_hex?: string
          primary_text_hex?: string
          secondary_hex?: string
          secondary_text_hex?: string
          seed_clamped?: Json | null
          spec_version?: number
          target?: string
          type_pairing_id?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "site_specs_brand_kit_id_fkey"
            columns: ["brand_kit_id"]
            isOneToOne: true
            referencedRelation: "brand_kits"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "site_specs_type_pairing_id_fkey"
            columns: ["type_pairing_id"]
            isOneToOne: false
            referencedRelation: "type_pairings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "site_specs_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      specialties: {
        Row: {
          active: boolean
          id: string
          label: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          id: string
          label: string
          sort_order: number
        }
        Update: {
          active?: boolean
          id?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      stripe_events: {
        Row: {
          payload: Json | null
          processed_at: string
          stripe_event_id: string
          type: string
        }
        Insert: {
          payload?: Json | null
          processed_at?: string
          stripe_event_id: string
          type: string
        }
        Update: {
          payload?: Json | null
          processed_at?: string
          stripe_event_id?: string
          type?: string
        }
        Relationships: []
      }
      subscriptions: {
        Row: {
          active: boolean | null
          cancel_at_period_end: boolean
          created_at: string
          current_period_end: string | null
          id: string
          organization_id: string | null
          status: string
          stripe_price_id: string | null
          stripe_subscription_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          active?: never
          cancel_at_period_end?: boolean
          created_at?: string
          current_period_end?: string | null
          id?: string
          organization_id?: string | null
          status: string
          stripe_price_id?: string | null
          stripe_subscription_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          active?: never
          cancel_at_period_end?: boolean
          created_at?: string
          current_period_end?: string | null
          id?: string
          organization_id?: string | null
          status?: string
          stripe_price_id?: string | null
          stripe_subscription_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "subscriptions_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscriptions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      tone_cards: {
        Row: {
          active: boolean
          id: string
          keywords: string[]
          sample_hero: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          id: string
          keywords: string[]
          sample_hero: string
          sort_order: number
        }
        Update: {
          active?: boolean
          id?: string
          keywords?: string[]
          sample_hero?: string
          sort_order?: number
        }
        Relationships: []
      }
      type_pairings: {
        Row: {
          active: boolean
          body_font: string
          google_fonts_url: string
          heading_font: string
          id: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          body_font: string
          google_fonts_url: string
          heading_font: string
          id: string
          sort_order: number
        }
        Update: {
          active?: boolean
          body_font?: string
          google_fonts_url?: string
          heading_font?: string
          id?: string
          sort_order?: number
        }
        Relationships: []
      }
      usp_fingerprints: {
        Row: {
          brief_id: string
          created_at: string
          id: string
          normalized: string
          scope_key: string
          statement: string
          user_id: string
        }
        Insert: {
          brief_id: string
          created_at?: string
          id?: string
          normalized: string
          scope_key: string
          statement: string
          user_id: string
        }
        Update: {
          brief_id?: string
          created_at?: string
          id?: string
          normalized?: string
          scope_key?: string
          statement?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "usp_fingerprints_brief_id_fkey"
            columns: ["brief_id"]
            isOneToOne: true
            referencedRelation: "project_briefs"
            referencedColumns: ["project_id"]
          },
        ]
      }
      usp_stopwords: {
        Row: {
          word: string
        }
        Insert: {
          word: string
        }
        Update: {
          word?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      accept_org_invite: { Args: { p_token: string }; Returns: string }
      assert_tenancy_invariants: {
        Args: Record<PropertyKey, never>
        Returns: undefined
      }
      brand_kit_direction_contrast: {
        Args: { p_direction: Json }
        Returns: Json
      }
      brand_kit_direction_palette_hash: {
        Args: { p_palette: Json }
        Returns: string
      }
      brand_kit_directions_contrasted: { Args: { p: Json }; Returns: boolean }
      brand_kit_directions_rendering_valid: {
        Args: { p: Json }
        Returns: boolean
      }
      brand_kit_directions_shape_valid: { Args: { p: Json }; Returns: boolean }
      brand_kit_entitled: { Args: { p_brand_kit_id: string }; Returns: boolean }
      brand_kit_entitling_statuses: {
        Args: Record<PropertyKey, never>
        Returns: string[]
      }
      brand_kit_ethics_check_valid: { Args: { p: Json }; Returns: boolean }
      brand_kit_hero_valid: { Args: { p: Json }; Returns: boolean }
      brand_kit_is_owned: { Args: { p_brand_kit_id: string }; Returns: boolean }
      brand_kit_palette_valid: { Args: { p: Json }; Returns: boolean }
      brand_kit_reveal_get: { Args: { p_brand_kit_id: string }; Returns: Json }
      brand_kit_select_direction: {
        Args: { p_brand_kit_id: string; p_direction_id: string }
        Returns: Json
      }
      brand_kit_selection_valid: {
        Args: { p_directions: Json; p_selected: string }
        Returns: boolean
      }
      brand_kit_social_templates_rendering_valid: {
        Args: { p: Json }
        Returns: boolean
      }
      brand_kit_social_templates_shape_valid: {
        Args: { p: Json }
        Returns: boolean
      }
      brand_kit_voice_guide_valid: { Args: { p: Json }; Returns: boolean }
      brief_completed_steps_renumber_up: {
        Args: { p_steps: number[] }
        Returns: number[]
      }
      brief_preview: { Args: { p_brief_id: string }; Returns: Json }
      brief_progress_step_renumber_up: {
        Args: { p_progress: number }
        Returns: number
      }
      brief_step_renumber_up: { Args: { p_step: number }; Returns: number }
      calendar_summary: {
        Args: { p_month: string; p_user_id: string }
        Returns: Json
      }
      can_access_brand_kit: {
        Args: { p_brand_kit_id: string }
        Returns: boolean
      }
      can_access_org_logo_path: { Args: { p_name: string }; Returns: boolean }
      can_access_project: { Args: { p_project_id: string }; Returns: boolean }
      comp_access_active: { Args: Record<PropertyKey, never>; Returns: boolean }
      comp_grant_active: { Args: { p_user_id: string }; Returns: boolean }
      comp_grant_credits: { Args: { p_user_id: string }; Returns: number }
      complete_choose_direction: {
        Args: { p_brand_kit_id: string }
        Returns: undefined
      }
      consume_generation_credit: {
        Args: { p_brand_kit_id: string }
        Returns: boolean
      }
      create_default_organization_for_user: {
        Args: { p_user_id: string }
        Returns: string
      }
      create_org_invite: {
        Args: { p_email: string; p_org_id: string; p_project_id?: string }
        Returns: string
      }
      direction_assets_claim: {
        Args: {
          p_brand_kit_id: string
          p_cost_estimate_cents: number
          p_daily_cap_cents: number
          p_direction_index: number
          p_palette_hash: string
          p_reclaim_after?: string
        }
        Returns: Json
      }
      direction_assets_mark_failed: {
        Args: { p_asset_id: string; p_claim_token: string }
        Returns: Json
      }
      direction_assets_mark_ready: {
        Args: {
          p_asset_id: string
          p_claim_token: string
          p_cost_cents: number
          p_storage_path: string
          p_url: string
        }
        Returns: Json
      }
      direction_limits: { Args: Record<PropertyKey, never>; Returns: Json }
      ensure_month_skeleton: {
        Args: { p_month: string; p_user_id: string }
        Returns: number
      }
      grant_plan_allowance: {
        Args: { p_grant_key?: string; p_project_id: string; p_tier: string }
        Returns: boolean
      }
      is_org_member: { Args: { p_org_id: string }; Returns: boolean }
      is_org_owner: { Args: { p_org_id: string }; Returns: boolean }
      preview_org_invite: {
        Args: { p_token: string }
        Returns: {
          invited_email: string
          organization_name: string
        }[]
      }
      project_briefs_data_valid: { Args: { p: Json }; Returns: boolean }
      project_briefs_tone_cards_valid: { Args: { p: Json }; Returns: boolean }
      project_briefs_usp_options_valid: { Args: { p: Json }; Returns: boolean }
      purchase_status_before: {
        Args: { p_purchase_id: string; p_status: string }
        Returns: string
      }
      record_purchase_status_event: {
        Args: {
          p_amount_cents?: number
          p_event_type: string
          p_new_status: string
          p_occurred_at?: string
          p_purchase_id: string
          p_stripe_event_id: string
        }
        Returns: boolean
      }
      remove_org_member: { Args: { p_member_id: string }; Returns: undefined }
      section_type_fields_valid: { Args: { p: Json }; Returns: boolean }
      seed_launch_checklist: {
        Args: { p_brand_kit_id: string }
        Returns: number
      }
      seed_site_spec: { Args: { p_brand_kit_id: string }; Returns: number }
      show_limit: { Args: Record<PropertyKey, never>; Returns: number }
      show_trgm: { Args: { "": string }; Returns: string[] }
      site_catalog: { Args: Record<PropertyKey, never>; Returns: Json }
      site_output_catalog_version: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      site_output_fill: {
        Args: { p_template: string; p_vars: Json }
        Returns: string
      }
      site_output_fragments: { Args: { p_target: string }; Returns: Json }
      site_output_get: {
        Args: { p_brand_kit_id: string; p_format?: string; p_target?: string }
        Returns: Json
      }
      site_output_mark_copied: {
        Args: { p_brand_kit_id: string }
        Returns: Json
      }
      site_output_step_title_count: {
        Args: { p_title: string }
        Returns: number
      }
      site_spec_accent_try: {
        Args: {
          p_check_distance: boolean
          p_deg: number
          p_light_neutral: string
          p_primary: string
          p_secondary: string
        }
        Returns: string
      }
      site_spec_clamp_note: {
        Args: { p_key: string; p_max: number; p_original: string }
        Returns: Json
      }
      site_spec_constraint_lines: {
        Args: { p_frag: Json; p_spec: Json }
        Returns: string[]
      }
      site_spec_contrast: { Args: { p_spec: Json }; Returns: Json }
      site_spec_contrast_level: { Args: { p_ratio: number }; Returns: string }
      site_spec_contrast_ratio: {
        Args: { p_bg: string; p_fg: string }
        Returns: number
      }
      site_spec_copy_blocks: { Args: { p_spec: Json }; Returns: Json }
      site_spec_credential_line: {
        Args: { p_details: Json; p_frag: Json }
        Returns: string
      }
      site_spec_cta_ink: {
        Args: { p_dark_neutral_hex: string; p_primary_hex: string }
        Returns: string
      }
      site_spec_cta_target_url_valid: { Args: { p: Json }; Returns: boolean }
      site_spec_curated_accent: { Args: { p_palette: Json }; Returns: string }
      site_spec_default_pages: {
        Args: { p_personas: string[]; p_specialties: string[] }
        Returns: Json
      }
      site_spec_default_target: {
        Args: { p_brand_kit_id: string }
        Returns: string
      }
      site_spec_delta_e: { Args: { p_a: string; p_b: string }; Returns: number }
      site_spec_derive_accent: {
        Args: {
          p_light_neutral: string
          p_primary: string
          p_secondary: string
        }
        Returns: string
      }
      site_spec_diff: { Args: { p_spec: Json }; Returns: Json }
      site_spec_entitlement_error: {
        Args: { p_brand_kit_id: string }
        Returns: Json
      }
      site_spec_envelope: { Args: { p_row: Json }; Returns: Json }
      site_spec_error: {
        Args: { p_code: string; p_field?: string; p_message: string }
        Returns: Json
      }
      site_spec_first_overlong_field: {
        Args: { p_pages: Json }
        Returns: string
      }
      site_spec_fix_contrast: {
        Args: { p_brand_kit_id: string; p_pair_id: string }
        Returns: Json
      }
      site_spec_get: { Args: { p_brand_kit_id: string }; Returns: Json }
      site_spec_hero_lengths_valid: { Args: { p: Json }; Returns: boolean }
      site_spec_hero_valid: { Args: { p: Json }; Returns: boolean }
      site_spec_hex_to_hsl: { Args: { p_hex: string }; Returns: number[] }
      site_spec_hsl_to_hex: {
        Args: { p_h: number; p_l: number; p_s: number }
        Returns: string
      }
      site_spec_hue_tolerance: {
        Args: { p_saturation: number }
        Returns: number
      }
      site_spec_identity_lines: {
        Args: { p_frag: Json; p_spec: Json }
        Returns: string
      }
      site_spec_lab: { Args: { p_hex: string }; Returns: number[] }
      site_spec_limits: { Args: Record<PropertyKey, never>; Returns: Json }
      site_spec_output: {
        Args: { p_spec: Json; p_target?: string }
        Returns: Json
      }
      site_spec_output_prompt: {
        Args: { p_spec: Json; p_target: string }
        Returns: Json
      }
      site_spec_output_render: {
        Args: { p_markdown: boolean; p_output: Json; p_spec: string }
        Returns: string
      }
      site_spec_output_setup_sheet: {
        Args: { p_spec: Json; p_target: string }
        Returns: Json
      }
      site_spec_page_keys: {
        Args: Record<PropertyKey, never>
        Returns: string[]
      }
      site_spec_pages_copy: { Args: { p_pages: Json }; Returns: Json }
      site_spec_pages_lengths_valid: { Args: { p: Json }; Returns: boolean }
      site_spec_pages_skeleton: { Args: { p_pages: Json }; Returns: Json }
      site_spec_pages_valid: { Args: { p: Json }; Returns: boolean }
      site_spec_palette_role: {
        Args: { p_palette: Json; p_role: string }
        Returns: string
      }
      site_spec_patch: {
        Args: { p_brand_kit_id: string; p_patch: Json }
        Returns: Json
      }
      site_spec_patchable_keys: {
        Args: Record<PropertyKey, never>
        Returns: string[]
      }
      site_spec_practice_detail_keys: {
        Args: Record<PropertyKey, never>
        Returns: string[]
      }
      site_spec_practice_details_valid: { Args: { p: Json }; Returns: boolean }
      site_spec_preview_model: { Args: { p_spec: Json }; Returns: Json }
      site_spec_relative_luminance: { Args: { p_hex: string }; Returns: number }
      site_spec_render_field: {
        Args: { p_field: Json; p_value: Json }
        Returns: string
      }
      site_spec_render_field_or_null: {
        Args: { p_field: Json; p_value: Json }
        Returns: string
      }
      site_spec_reset: {
        Args: { p_brand_kit_id: string; p_scope?: string }
        Returns: Json
      }
      site_spec_retired_clamp_keys: {
        Args: { p_patch: Json }
        Returns: string[]
      }
      site_spec_section_fields: {
        Args: { p_section: Json; p_spec: Json }
        Returns: Json
      }
      site_spec_section_types: {
        Args: Record<PropertyKey, never>
        Returns: string[]
      }
      site_spec_seed_clamped_valid: { Args: { p: Json }; Returns: boolean }
      site_spec_seed_values: { Args: { p_brand_kit_id: string }; Returns: Json }
      site_spec_set_target: {
        Args: { p_brand_kit_id: string; p_target: string }
        Returns: Json
      }
      site_spec_structure_lines: {
        Args: { p_frag: Json; p_spec: Json }
        Returns: string
      }
      site_spec_suggest_hex: {
        Args: { p_fixed_hex: string; p_move_hex: string; p_target?: number }
        Returns: string
      }
      site_spec_text_variant: {
        Args: { p_brand_hex: string; p_paper_hex: string }
        Returns: string
      }
      site_spec_token_lines: {
        Args: { p_frag: Json; p_spec: Json }
        Returns: string
      }
      site_spec_variant_of: {
        Args: { p_role: string; p_spec: Json }
        Returns: string
      }
      site_spec_voice_guide: { Args: { p_spec: Json }; Returns: Json }
      site_spec_voice_lines: {
        Args: { p_frag: Json; p_spec: Json }
        Returns: string
      }
      truncate_on_word_boundary: {
        Args: { p_max: number; p_text: string }
        Returns: string
      }
      usp_banned_phrases_check: { Args: { p_text: string }; Returns: string[] }
      usp_check_distinct: {
        Args: {
          p_exclude_brief?: string
          p_scope_key: string
          p_statement: string
        }
        Returns: Json
      }
      usp_fingerprint_confirm: {
        Args: { p_brief_id: string; p_statement: string }
        Returns: string
      }
      usp_normalize: { Args: { p_text: string }; Returns: string }
      validate_field_sources: { Args: { p: Json }; Returns: boolean }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const

