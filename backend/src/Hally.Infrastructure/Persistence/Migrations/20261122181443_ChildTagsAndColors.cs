using System;
using System.Collections.Generic;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class ChildTagsAndColors : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<List<Guid>>(
                name: "child_ids",
                table: "tasks",
                type: "uuid[]",
                nullable: false,
                defaultValueSql: "'{}'::uuid[]");

            migrationBuilder.AddColumn<List<Guid>>(
                name: "child_ids",
                table: "events",
                type: "uuid[]",
                nullable: false,
                defaultValueSql: "'{}'::uuid[]");

            migrationBuilder.AddColumn<string>(
                name: "color",
                table: "children",
                type: "character varying(16)",
                maxLength: 16,
                nullable: false,
                defaultValue: "sky");

            // Keep existing tags, and give existing siblings different colours in the order they were added.
            migrationBuilder.Sql("UPDATE tasks SET child_ids = ARRAY[child_id] WHERE child_id IS NOT NULL;");
            migrationBuilder.Sql("UPDATE events SET child_ids = ARRAY[child_id] WHERE child_id IS NOT NULL;");
            migrationBuilder.Sql("""
                UPDATE children c SET color = (ARRAY['sky','mint','lavender','sun','teal','indigo'])[((r.n - 1) % 6) + 1]
                FROM (SELECT id, row_number() OVER (PARTITION BY family_id ORDER BY created_at) AS n FROM children) r
                WHERE c.id = r.id;
                """);

            migrationBuilder.DropColumn(
                name: "child_id",
                table: "tasks");

            migrationBuilder.DropColumn(
                name: "child_id",
                table: "events");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "child_id",
                table: "tasks",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "child_id",
                table: "events",
                type: "uuid",
                nullable: true);

            migrationBuilder.Sql("UPDATE tasks SET child_id = child_ids[1];");
            migrationBuilder.Sql("UPDATE events SET child_id = child_ids[1];");

            migrationBuilder.DropColumn(
                name: "child_ids",
                table: "tasks");

            migrationBuilder.DropColumn(
                name: "child_ids",
                table: "events");

            migrationBuilder.DropColumn(
                name: "color",
                table: "children");
        }
    }
}
